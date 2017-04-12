defmodule Sippet.Transaction.Test do
  use ExUnit.Case, async: false

  alias Sippet.Message

  import Mock

  test "client invite transaction" do
    alias Sippet.Transaction.Client
    alias Sippet.Transaction.Client.State
    alias Sippet.Transaction.Client.Invite

    request =
      """
      INVITE sip:bob@biloxi.com SIP/2.0
      Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds
      Max-Forwards: 70
      To: Bob <sip:bob@biloxi.com>
      From: Alice <sip:alice@atlanta.com>;tag=1928301774
      Call-ID: a84b4c76e66710@pc33.atlanta.com
      CSeq: 314159 INVITE
      Contact: <sip:alice@pc33.atlanta.com>
      """
      |> Message.parse!()

    transaction = Client.new(request)

    assert transaction.branch == "z9hG4bK776asdhds"
    assert transaction.method == :invite

    state = State.new(request, transaction)

    # --- test the calling state

    # test if the retry timer has been started for unreliable transports, and
    # if the received request is sent to the core
    with_mock Sippet.Transport,
        [send_message: fn _, _ -> :ok end,
         reliable?: fn _ -> false end] do

      {:keep_state_and_data, actions} =
          Invite.calling(:enter, :none, state)

      assert_action_timeout actions, 600

      assert called Sippet.Transport.reliable?(request)
      assert called Sippet.Transport.send_message(request, transaction)
    end

    # test if the timeout timer has been started for reliable transports
    with_mock Sippet.Transport,
        [send_message: fn _, _ -> :ok end,
         reliable?: fn _ -> true end] do

      {:keep_state_and_data, actions} =
        Invite.calling(:enter, :none, state)

      assert_action_timeout actions, 64 * 600

      assert called Sippet.Transport.reliable?(request)
      assert called Sippet.Transport.send_message(request, transaction)
    end

    # test timer expiration for unreliable transports
    with_mock Sippet.Transport,
        [send_message: fn _, _ -> :ok end,
         reliable?: fn _ -> false end] do

      {:keep_state_and_data, actions} =
        Invite.calling(:state_timeout, {1200, 1200}, state)

      assert_action_timeout actions, 2400

      assert called Sippet.Transport.send_message(request, transaction)
    end

    # test timeout and errors
    with_mock Sippet.Core,
        [receive_error: fn _, _ -> :ok end] do
      {:stop, :shutdown, _data} =
        Invite.calling(:state_timeout, {6000, 64 * 600}, state)

      {:stop, :shutdown, _data} =
        Invite.calling(:cast, {:error, :uh_oh}, state)
    end

    # test state transitions that depend on the reception of responses with
    # different status codes
    with_mock Sippet.Core,
        [receive_response: fn _, _ -> :ok end] do
      response = Message.build_response(request, 100)
      {:next_state, :proceeding, _data} =
        Invite.calling(:cast, {:incoming_response, response}, state)
      
      response = Message.build_response(request, 200)
      {:stop, :normal, _data} =
        Invite.calling(:cast, {:incoming_response, response}, state)
      
      response = Message.build_response(request, 400)
      {:next_state, :completed, _data} =
        Invite.calling(:cast, {:incoming_response, response}, state)
    end

    # --- test the proceeding state

    # check state transitions depending on the received responses
    with_mock Sippet.Core,
        [receive_response: fn _, _ -> :ok end] do

      :keep_state_and_data = Invite.proceeding(:enter, :calling, state)

      response = Message.build_response(request, 180)
      {:keep_state, _data} =
        Invite.proceeding(:cast, {:incoming_response, response}, state)
      
      response = Message.build_response(request, 200)
      {:stop, :normal, _data} =
        Invite.proceeding(:cast, {:incoming_response, response}, state)
      
      response = Message.build_response(request, 400)
      {:next_state, :completed, _data} =
        Invite.proceeding(:cast, {:incoming_response, response}, state)
    end

    # this is not part of the standard, but may occur in exceptional cases
    with_mock Sippet.Core,
        [receive_error: fn _, _ -> :ok end] do
      {:stop, :shutdown, _data} =
        Invite.proceeding(:cast, {:error, :uh_oh}, state)
    end

    # --- test the completed state

    # test the ACK request creation
    with_mock Sippet.Transport,
        [send_message: fn _, _ -> :ok end,
         reliable?: fn _ -> false end] do
      last_response = Message.build_response(request, 400)
      %{extras: extras} = state
      extras = extras |> Map.put(:last_response, last_response)

      {:keep_state, data, actions} =
        Invite.completed(:enter, :proceeding, %{state | extras: extras})

      assert_action_timeout actions, 32000

      %{extras: %{ack: ack}} = data
      assert :ack == ack.start_line.method
      assert :ack == ack.headers.cseq |> elem(1)
    
      # ACK is retransmitted case another response comes in
      :keep_state_and_data =
        Invite.completed(:cast, {:incoming_response, last_response}, data)

      assert called Sippet.Transport.send_message(ack, transaction)
    end

    # reliable transports don't keep the completed state
    with_mock Sippet.Transport,
        [send_message: fn _, _ -> :ok end,
         reliable?: fn _ -> true end] do
      last_response = Message.build_response(request, 400)
      %{extras: extras} = state
      extras = extras |> Map.put(:last_response, last_response)

      {:stop, :normal, data} =
        Invite.completed(:enter, :proceeding, %{state | extras: extras})

      %{extras: %{ack: ack}} = data
      assert :ack == ack.start_line.method
      assert :ack == ack.headers.cseq |> elem(1)
    end

    # check state completion after timer D
    {:stop, :normal, nil} =
      Invite.completed(:state_timeout, nil, nil)
  end

  defp assert_action_timeout(actions, delay) do
    timeout_actions =
      for x <- actions,
          {:state_timeout, ^delay, _data} = x do
        x
      end

    assert length(timeout_actions) == 1
  end
end
