%% @doc Low level packet buffer management.
-module(utp_buffer).

-include("log.hrl").
-include("utp.hrl").

-export([
         mk/1,

         init_counters/3,
         init_seqno/2,
         init_ackno/2,

         mk_random_seq_no/0,
         send_fin/2,
         send_ack/2,
         handle_packet/4,
         buffer_dequeue/1,
         buffer_putback/2,
         fill_window/3,

         advertised_window/1,

         extract_rtt/1,
         extract_payload_size/1,
         retransmit_packet/2
         ]).

-export([view_zerowindow_reopen/2]).

-export([draining_receive/2]).

%% DEFINES
%% ----------------------------------------------------------------------

%% The default RecvBuf size: 8K
-define(OPT_RECV_BUF, 8192).
-define(REORDER_BUFFER_MAX_SIZE, 511).

%% The deafult delays of acks
-define(DELAYED_ACK_BYTE_THRESHOLD, 2400). % bytes
-define(DELAYED_ACK_TIME_THRESHOLD, 100).  % ms

%% TYPES
%% ----------------------------------------------------------------------
-type message() :: send_ack.
-type messages() :: [message()].

-record(pkt_wrap, {
          packet            :: utp_proto:packet(),
          transmissions = 0 :: integer(),
          send_time = 0 :: integer(),
          need_resend = false :: boolean()
         }).
-type pkt() :: #pkt_wrap{}.


-record(buffer, {
          recv_buf    = queue:new()     :: queue(),
          reorder_buf = []              :: orddict:orddict(),
          %% When we have a working protocol, this retransmission queue is probably
          %% Optimization candidate 1 :)
          retransmission_queue = []     :: [#pkt_wrap{}],
          reorder_count = 0             :: integer(), % When and what to reorder
          next_expected_seq_no = 1      :: 0..16#FFFF, % Next expected packet
          seq_no = 1                    :: 0..16#FFFF, % Next Sequence number to use when sending

          %% Did we receive a fin packet?
          fin_state = none :: none | {got_fin, 0..16#FFFF},

          %% Packet buffer settings
          %% --------------------
          %% Same, for the recv buffer
          opt_recv_buf_sz = ?OPT_RECV_BUF :: integer(),

          %% The maximal size of packets.
          %% @todo Discover this one
          pkt_size = 1000 :: integer()
         }).
-opaque t() :: #buffer{}.

%% Track send quota available
-record(send_quota, {
          send_quota :: integer(),
          last_send_quota :: integer()
         }).
-type quota() :: #send_quota{}.

-export_type([pkt/0,
              t/0,
              messages/0,
              quota/0]).

%% API
%% ----------------------------------------------------------------------

%% PKT BUF INITIALIZATION
%% ----------------------------------------------------------------------
mk(none)    -> #buffer{};
mk(OptRecv) ->
    #buffer {
        opt_recv_buf_sz = OptRecv
       }.

init_counters(#buffer{} = PBuf, SeqNo, NextExpected)
  when SeqNo >= 0, SeqNo < 65536,
       NextExpected >= 0, NextExpected < 65536 ->
    PBuf#buffer { seq_no = SeqNo,
                  next_expected_seq_no = NextExpected}.

init_seqno(#buffer {} = PBuf, SeqNo) when SeqNo >= 0, SeqNo < 65536->
    PBuf#buffer { seq_no = SeqNo }.

init_ackno(#buffer{} = PBuf, NextExpected) ->
    PBuf#buffer {next_expected_seq_no = NextExpected}.

mk_random_seq_no() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.


%% SEND SPECIFIC PACKET TYPES
%% ----------------------------------------------------------------------

%% @doc Toss out an ACK packet on the Socket.
%% @end
send_ack(Network,
         #buffer { seq_no = SeqNo,
                    next_expected_seq_no = AckNo
                  } = Buf) ->
    %% @todo Send out an ack message here
    AckPacket = #packet { ty = st_state,
                          seq_no = utp_util:bit16(SeqNo-1), % @todo Is this right?
                          ack_no = utp_util:bit16(AckNo-1), % We are recording the next expected ack number
                          extension = []
                        },
    Win = advertised_window(Buf),
    case utp_network:send_pkt(Win, Network, AckPacket) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?WARN([dropping_packet, {error, Reason}]),
            ok
    end.

%% @doc Toss out a FIN packet on the Socket.
%% @todo Reconsider this. It may be it should be a normally streamed pkt
%%       rather than this variant where we send a special packet with
%%       FIN set.
%% @end
send_fin(Network, Buf) ->
    send_packet(st_fin, <<>>, % Empty packet for now
                Buf, Network).

send_packet(Bin, Buf, Network) ->
    send_packet(st_data, Bin, Buf, Network).

send_packet(Ty, Bin,
            #buffer { seq_no = SeqNo,
                       next_expected_seq_no = AckNo,
                       retransmission_queue = RetransQueue } = Buf,
            Network) ->
    P = #packet { ty = Ty,
                  seq_no  = SeqNo,
                  ack_no  = utp_util:bit16(AckNo-1),
                  extension = [],
                  payload = Bin },
    Win = advertised_window(Buf),
    {ok, SendTime} = utp_network:send_pkt(Win, Network, P),
    Wrap = #pkt_wrap { packet = P,
                       transmissions = 1,
                       send_time = SendTime,
                       need_resend = false },
    Buf#buffer { seq_no = utp_util:bit16(SeqNo+1),
                  retransmission_queue = [Wrap | RetransQueue]
                }.

%% RECEIVE PATH
%% ----------------------------------------------------------------------

%% @doc Given a Sequence Number in a packet, validate it
%% The `SeqNo' given is validated with respect to the current state of
%% the connection.
%% @end
validate_seq_no(SeqNo, #buffer { next_expected_seq_no = NextExpected }) ->
    Diff = utp_util:bit16(SeqNo - NextExpected),
    DiffMinusOne   = utp_util:bit16(SeqNo - (NextExpected - 1)),
    case Diff of
        _SeqAhead when DiffMinusOne == 0 ->
            {ok, no_data};
        SeqAhead when SeqAhead >= ?REORDER_BUFFER_SIZE ->
            {error, is_far_in_future};
        SeqAhead ->
            {ok, SeqAhead}
    end.

%% @doc Assert that the current state is valid for Data packets
%% @todo This may need to accept other packet types!
%% @end
-spec valid_state(atom()) -> ok.
valid_state(State) ->
    case State of
        connected -> ok;
        fin_sent -> ok;
        _ -> throw({no_data, State})
    end.

%% @doc Consider if we should send out an ACK
%%   The Rule for ACK'ing is that the packet has altered the reorder buffer in any
%%   way for us. If the incoming packet has, we should let the other end know this.
%%   If the packet does not alter the reorder buffer however, we know it was either
%%   payload-less or duplicate (the latter is handled elsewhere). Payload-less packets
%%   are informational only, and if they generate ACK's it is not from this part of
%%   the code.
%% @end
consider_send_ack(#buffer { reorder_buf = RB1,
                             next_expected_seq_no = Seq1 },
                  #buffer { reorder_buf = RB2,
                             next_expected_seq_no = Seq2})
  when RB1 =/= RB2 orelse Seq1 =/= Seq2 ->
    [{send_ack, true}];
consider_send_ack(_, _) -> [].
       
%% @doc Update the receive buffer with Payload
%% This function will update the receive buffer with some incoming payload.
%% It will also return back to us a message if we should ack the incoming
%% packet. As such, this function wraps some lower-level operations,
%% with respect to incoming payload.
%% @end                      
handle_receive_buffer(SeqNo, Payload, PacketBuffer, State) ->
    case update_recv_buffer(SeqNo, Payload, PacketBuffer, State) of
        %% Force an ACK out in this case
        duplicate -> {PacketBuffer, [{send_ack, true}]};
        {ok, #buffer{} = PB} -> {PB, consider_send_ack(PacketBuffer, PB)};
        {got_fin, #buffer{} = PB} -> {PB, [{got_fin, true},
                                           {send_ack, true}]} % *Always* ACK the FIN packet!
    end.


%% @doc Handle incoming Payload in datagrams
%% A Datagram came in with SeqNo and Payload. This Payload and SeqNo
%% updates the PacketBuffer if the SeqNo is valid for the current
%% state of the connection.
%% @end
handle_incoming_datagram_payload(SeqNo, Payload, PacketBuffer, State) ->
    %% We got a packet in with a seq_no and some things to ack.
    %% Validate the sequence number.
    case validate_seq_no(SeqNo, PacketBuffer) of
        {ok, no_data} ->
            no_data;
        {ok, _Num} ->
            %% Handle the Payload by Dumping it into the packet buffer
            %% at the right point Returns a new PacketBuffer, and a
            %% list of Messages for the upper layer
            {ok, handle_receive_buffer(SeqNo, Payload, PacketBuffer, State)};
        {error, Violation} ->
            throw({error, Violation})
    end.




%% @doc Update the Receive Buffer with Payload
%% There are essentially two cases: Either the packet is the next
%% packet in sequence, so we can simply push it directly to the
%% receive buffer right away. Then we can check the reorder buffer to
%% see if we can satisfy more packets from it. If it is not in
%% sequence, it should go into the reorder buffer in the right spot.
%% @end
update_recv_buffer(SeqNo, <<>>,
                   #buffer { fin_state = {got_fin, SeqNo},
                             next_expected_seq_no = SeqNo } = PacketBuffer, _State) ->
    {got_fin, PacketBuffer#buffer { next_expected_seq_no = utp_util:bit16(SeqNo+1)}};
update_recv_buffer(_SeqNo, <<>>, PB, _State) -> {ok, PB};
update_recv_buffer(SeqNo, Payload, #buffer { fin_state = {got_fin, SeqNo},
                                             next_expected_seq_no = SeqNo } = PB, State) ->
    N_PB = recv_buffer_enqueue(State, Payload, PB),
    {got_fin, N_PB#buffer { next_expected_seq_no = utp_util:bit16(SeqNo+1)}};
update_recv_buffer(SeqNo, Payload, #buffer { next_expected_seq_no = SeqNo } = PB, State) ->
    N_PB = recv_buffer_enqueue(State, Payload, PB),
    satisfy_from_reorder_buffer(
      N_PB#buffer { next_expected_seq_no = utp_util:bit16(SeqNo+1) }, State);
update_recv_buffer(SeqNo, Payload, PB, _State) when is_integer(SeqNo) ->
    reorder_buffer_in(SeqNo, Payload, PB).

recv_buffer_enqueue(fin_sent, _, PB) -> PB;
recv_buffer_enqueue(connected, Payload, PB) -> enqueue_payload(Payload, PB).

%% @doc Try to satisfy the next_expected_seq_no directly from the reorder buffer.
%% @end
satisfy_from_reorder_buffer(#buffer { reorder_buf = [] } = PB, _State) ->
    {ok, PB};
satisfy_from_reorder_buffer(#buffer { next_expected_seq_no = AckNo,
                                       fin_state = {got_fin, AckNo},
                                       reorder_buf = [{AckNo, PL} | R]} = PB, State) ->
    N_PB = recv_buffer_enqueue(State, PL, PB),
    {got_fin, N_PB#buffer { next_expected_seq_no = utp_util:bit16(AckNo+1),
                             reorder_buf = R}};
satisfy_from_reorder_buffer(#buffer { next_expected_seq_no = AckNo,
                                       reorder_buf = [{AckNo, PL} | R]} = PB,
                            State) ->
    N_PB = recv_buffer_enqueue(State, PL, PB),
    satisfy_from_reorder_buffer(
      N_PB#buffer { next_expected_seq_no = utp_util:bit16(AckNo+1),
                     reorder_buf = R}, State);
satisfy_from_reorder_buffer(#buffer { } = PB, _State) ->
    {ok, PB}.

%% @doc Enter the packet into the reorder buffer, watching out for duplicates
%% @end
reorder_buffer_in(SeqNo, Payload, #buffer { reorder_buf = OD } = PB) ->
    case orddict:is_key(SeqNo, OD) of
        true -> duplicate;
        false -> {ok, PB#buffer { reorder_buf = orddict:store(SeqNo, Payload, OD) }}
    end.

%% SEND PATH
%% ----------------------------------------------------------------------

update_send_buffer(AckNo, #buffer { seq_no = NextSeqNo } = PB) ->
    SeqNo = utp_util:bit16(NextSeqNo - 1),
    WindowSize = send_window_count(PB),
    WindowStart = utp_util:bit16(SeqNo - WindowSize),
    case view_ack_no(AckNo, WindowStart, WindowSize) of
        {ok, AcksAhead} ->
            {Ret, AckedPs, PB1} = prune_acked(AcksAhead, WindowStart, PB),
            FinState = case Ret of
                           ok -> [];
                           fin_sent_acked -> [fin_sent_acked]
                       end,
            {ok, FinState ++ view_ack_state(length(AckedPs), PB1),
                 AckedPs,
                 PB1};
        {ack_is_old, _AcksAhead} ->
            {ok, [{old_ack, true}], [], PB}
    end.

%% @doc Prune the retransmission queue for ACK'ed packets.
%% Prune out all packets from `WindowStart' and `AcksAhead' in. Return a new packet
%% buffer where the retransmission queue has been updated.
%% @todo All this AcksAhead business, why? We could as well just work directly on
%%       the ack_no I think.
%% @end
prune_acked(AckAhead, WindowStart,
            #buffer { retransmission_queue = RQ } = PB) ->
    {AckedPs, N_RQ} = lists:partition(
                        fun(#pkt_wrap {
                               packet = #packet { seq_no = SeqNo } }) ->
                                Distance = utp_util:bit16(SeqNo - WindowStart),
                                Distance =< AckAhead
                        end,
                        RQ),
    
    RetState = case contains_st_fin(AckedPs) of
                   true ->
                       fin_sent_acked;
                   false ->
                       ok
               end,
    {RetState, AckedPs, PB#buffer { retransmission_queue = N_RQ }}.

contains_st_fin([]) -> false;
contains_st_fin([#pkt_wrap {
                    packet = #packet { ty = st_fin }} | _]) ->
    true;
contains_st_fin([_ | R]) ->
    contains_st_fin(R).

view_ack_state(0, _PB) -> [];
view_ack_state(N, PB) when is_integer(N) ->
    case has_inflight_data(PB) of
        true ->
            [{data_inflight, true}];
        false ->
            [{all_acked, true}]
    end.

has_inflight_data(#buffer { retransmission_queue = [] }) -> false;
has_inflight_data(#buffer { retransmission_queue = [_|_] }) -> true.

%% @doc View the state of the Ack
%% Given the `AckNo' and when the `WindowStart' started, we scrutinize the Ack
%% for correctness according to age. If the ACK is old, tell the caller.
%% @end
view_ack_no(AckNo, WindowStart, WindowSize) ->
    case utp_util:bit16(AckNo - WindowStart) of
        N when N > WindowSize ->
            %% The ack number is old, so do essentially nothing in the next part
            {ack_is_old, N};
        N when is_integer(N) ->
            {ok, N}
    end.

send_window_count(#buffer { retransmission_queue = RQ }) ->
    length(RQ).



%% INCOMING PACKETS
%% ----------------------------------------------------------------------

%% @doc Handle an incoming Packet
%% We proceed to handle an incoming packet by first seeing if it has
%% payload we are interested in, and if that payload advances our
%% buffers in any way. Then, afterwards, we handle the AckNo and
%% Advertised window of the packet to eventually send out more on the
%% socket towards the other end.
%% @end    
handle_packet(State,
              #packet { seq_no = SeqNo,
                        ack_no = AckNo,
                        payload = Payload,
                        win_sz  = WindowSize,
                        ty = Type },
              PktWindow,
              PacketBuffer) when PktWindow =/= undefined ->
    %% Assert that we are currently in a state eligible for receiving
    %% datagrams of this type. This assertion ought not to be
    %% triggered by our code.
    ok = valid_state(State),

    %% Some packets set a specific state we should handle in our end
    N_PacketBuffer = handle_packet_type(Type, SeqNo, PacketBuffer),

    %% Update the state by the receiving payload stuff.
    case handle_incoming_datagram_payload(SeqNo, Payload, N_PacketBuffer, State) of
        {ok, {N_PacketBuffer1, RecvMessages}} ->
            %% The Packet may have ACK'ed stuff from our send buffer. Update
            %% the send buffer accordingly
            {ok, SendMessages, AckedPs, N_PacketBuffer2} =
                update_send_buffer(AckNo, N_PacketBuffer1),

            {ok, N_PacketBuffer2,
             utp_network:handle_window_size(PktWindow, WindowSize),
             SendMessages ++ RecvMessages ++ [{acked, AckedPs}]};
        no_data when Type == st_state orelse Type == st_data ->
            %% The packet has no data
            {ok, SendMessages, _AcksAhead, N_PacketBuffer2} =
                update_send_buffer(AckNo, N_PacketBuffer),
            
            {ok, N_PacketBuffer2,
             utp_network:handle_window_size(PktWindow, WindowSize),
             SendMessages}
    end.


handle_packet_type(Type, SeqNo, Buf) ->
    case Type of
        st_fin ->
            et:trace_me(50, none, none, fin, [saw_st_fin, SeqNo]),
            Buf#buffer { fin_state = {got_fin, SeqNo} };
        st_data ->
            Buf;
        st_state ->
            Buf
    end.

%% PACKET TRANSMISSION
%% ----------------------------------------------------------------------

%% @doc Build up a queue of payload to send
%% This function builds up to `N' bytes to send out -- each packet up
%% to the packet size. The functions satisfies data from the
%% process_queue of processes waiting to get data sent. It returns an
%% updates ProcessQueue record and a `queue' of the packets that are
%% going out.
%% @end
fill_from_proc_queue(N, Buf, ProcQ) ->
    TxQ = queue:new(),
    fill_from_proc_queue(N, Buf#buffer.pkt_size, TxQ, ProcQ).

%% @doc Worker for fill_from_proc_queue/3
%% @end
-spec fill_from_proc_queue(integer(),
                           integer(),
                           queue(),
                           utp_process:t()) ->
                                  {window_maxed_out | ok, queue(), utp_process:t()}.
fill_from_proc_queue(0, _Sz, Q, Proc) ->
    {window_maxed_out, Q, Proc};
fill_from_proc_queue(N, MaxPktSz, Q, Proc) ->
    ToFill = case N =< MaxPktSz of
                 true -> N;
                 false -> MaxPktSz
             end,
    case utp_process:fill_via_send_queue(ToFill, Proc) of
        {filled, Bin, Proc1} ->
            fill_from_proc_queue(N - ToFill, MaxPktSz, queue:in(Bin, Q), Proc1);
        {partial, Bin, Proc1} ->
            {ok, queue:in(Bin, Q), Proc1};
        zero ->
            {ok, Q, Proc}
    end.

%% @doc Given a queue of things to send, transmit packets from it
%% @end
transmit_queue(Q, Buf, Network) ->
    L = queue:to_list(Q),
    lists:foldl(fun(Data, B) ->
                        send_packet(Data, B, Network)
                end,
                Buf,
                L).

%% @doc Fill up the Window with packets in the outgoing direction
%% @end
fill_window(Network, ProcQueue, PktBuf) ->
    FreeInWindow = bytes_free_in_window(PktBuf, Network),
    %% Fill a queue of stuff to transmit
    {Res, TxQueue, NProcQueue} = fill_from_proc_queue(FreeInWindow, PktBuf, ProcQueue),
    MaxOut = case Res of
                 ok ->
                     [];
                 window_maxed_out ->
                     [window_maxed_out]
             end,
    %% Send out the queue of packets to transmit
    NBuf1 = transmit_queue(TxQueue, PktBuf, Network),
    %% Eventually shove the Nagled packet in the tail
    Result = case queue:is_empty(TxQueue) of
                 true ->
                     [no_piggyback];
                 false ->
                     utp:report_event(90, us, sent_data, []),
                     [sent_data]
             end,
    {Result ++ MaxOut, NBuf1, NProcQueue}.

%% PACKET RETRANSMISSION
%% ----------------------------------------------------------------------

retransmit_packet(PktBuf, Network) ->
    {Oldest, Rest} = pick_oldest_packet(PktBuf),
    #pkt_wrap { packet = Pkt,
                transmissions = N } = Oldest,
    Win = advertised_window(PktBuf),
    {ok, SendTime} = utp_network:send_pkt(Win, Network, Pkt),
    Wrap = Oldest#pkt_wrap { transmissions = N+1,
                             send_time = SendTime},
    PktBuf#buffer { retransmission_queue = [Wrap | Rest] }.

pick_oldest_packet(#buffer { retransmission_queue = [Candidate | R] }) ->
    pick_oldest_packet(Candidate, R, []).

pick_oldest_packet(Candidate, [], Accum) ->
    {Candidate, lists:reverse(Accum)};
pick_oldest_packet(#pkt_wrap { packet = P1 } = C, [#pkt_wrap { packet = P2 } = W | R], Accum) ->
    case utp_socket:order_packets(P1, P2) of
        [P1, P2] ->
            pick_oldest_packet(C, R, [W | Accum]);
        [P2, P1] ->
            pick_oldest_packet(W, R, [C | Accum])
    end.

%% INTERNAL FUNCTIONS
%% ----------------------------------------------------------------------

%% @doc Return the size of the receive buffer
%% @end
recv_buf_size(Q) ->
    L = queue:to_list(Q),
    lists:sum([byte_size(Payload) || Payload <- L]).

%% @doc Calculate the advertised window to use
%% @end
advertised_window(#buffer { recv_buf = Q,
                             opt_recv_buf_sz = Sz }) ->
    FillValue = recv_buf_size(Q),
    case Sz - FillValue of
        N when N >= 0 ->
            N;
        N when N < 0 ->
            0 % Case happens when the sender forces a packet through
    end.

payload_size(#pkt_wrap { packet = Packet }) ->
    byte_size(Packet#packet.payload).


view_inflight_bytes(#buffer{ retransmission_queue = [] }) ->
    buffer_empty;
view_inflight_bytes(#buffer{ retransmission_queue = Q }) ->
    case lists:sum([payload_size(Pkt) || Pkt <- Q]) of
        Sum ->
            {ok, Sum}
    end.

bytes_free_in_window(PktBuf, Network) ->
    MaxSend = utp_network:max_window_send(Network),
    case view_inflight_bytes(PktBuf) of
        buffer_empty ->
            MaxSend;
        {ok, Inflight} when Inflight =< MaxSend ->
            MaxSend - Inflight;
        {ok, _Inflight} ->
            0
    end.

enqueue_payload(Payload, #buffer { recv_buf = Q } = PB) ->
    PB#buffer { recv_buf = queue:in(Payload, Q) }.

buffer_putback(B, #buffer { recv_buf = Q } = Buf) ->
    Buf#buffer { recv_buf = queue:in_r(B, Q) }.

buffer_dequeue(#buffer { recv_buf = Q } = Buf) ->
    case queue:out(Q) of
        {{value, E}, Q1} ->
            {ok, E, Buf#buffer { recv_buf = Q1 }};
        {empty, _} ->
            empty
    end.

extract_rtt(Packets) ->
    [TS || #pkt_wrap { send_time = TS} = P <- Packets,
           P#pkt_wrap.transmissions == 1].

extract_payload_size(Packets) ->
    lists:sum([byte_size(Pl) || #pkt_wrap { packet = #packet { payload = Pl } } <- Packets]).

                  




view_zerowindow_reopen(Old, New) ->
    N = advertised_window(Old),
    K = advertised_window(New),
    N == 0 andalso K > 1000. % Only open up the window when we have processed a considerable amount

draining_receive(L, PktBuf) ->
    case buffer_dequeue(PktBuf) of
        empty ->
            empty;
        {ok, Bin, N_Buffer} when byte_size(Bin) > L ->
            <<Cut:L/binary, Rest/binary>> = Bin,
            {ok, Cut, buffer_putback(Rest, N_Buffer)};
        {ok, Bin, N_Buffer} when byte_size(Bin) == L ->
            {ok, Bin, N_Buffer};
        {ok, Bin, N_Buffer} when byte_size(Bin) < L ->
            case draining_receive(L - byte_size(Bin), N_Buffer) of
                empty ->
                    {partial_read, Bin, N_Buffer};
                {ok, Bin2, N_Buffer2} ->
                    {ok, <<Bin/binary, Bin2/binary>>, N_Buffer2};
                {partial_read, Bin2, N_Buffer} ->
                    {partial_read, <<Bin/binary, Bin2/binary>>, N_Buffer}
            end
    end.
