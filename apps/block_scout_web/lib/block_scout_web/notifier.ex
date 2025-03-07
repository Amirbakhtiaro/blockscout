defmodule BlockScoutWeb.Notifier do
  @moduledoc """
  Responds to events by sending appropriate channel updates to front-end.
  """

  require Logger

  alias Absinthe.Subscription

  alias BlockScoutWeb.API.V2, as: API_V2

  alias BlockScoutWeb.{
    AddressContractVerificationViaFlattenedCodeView,
    AddressContractVerificationViaJsonView,
    AddressContractVerificationViaMultiPartFilesView,
    AddressContractVerificationViaStandardJsonInputView,
    AddressContractVerificationVyperView,
    Endpoint
  }

  alias Explorer.{Chain, Market, Repo}
  alias Explorer.Chain.Address.Counters
  alias Explorer.Chain.{Address, BlockNumberHelper, DenormalizationHelper, InternalTransaction, Transaction}
  alias Explorer.Chain.Supply.RSK
  alias Explorer.Chain.Transaction.History.TransactionStats
  alias Explorer.Counters.{AverageBlockTime, Helper}
  alias Explorer.SmartContract.{CompilerVersion, Solidity.CodeCompiler}
  alias Phoenix.View

  @check_broadcast_sequence_period 500

  case Application.compile_env(:explorer, :chain_type) do
    :arbitrum ->
      @chain_type_specific_events ~w(new_arbitrum_batches new_messages_to_arbitrum_amount)a

    _ ->
      nil
  end

  def handle_event({:chain_event, :addresses, type, addresses}) when type in [:realtime, :on_demand] do
    Endpoint.broadcast("addresses:new_address", "count", %{count: Counters.address_estimated_count()})

    addresses
    |> Stream.reject(fn %Address{fetched_coin_balance: fetched_coin_balance} -> is_nil(fetched_coin_balance) end)
    |> Enum.each(&broadcast_balance/1)
  end

  def handle_event({:chain_event, :address_coin_balances, type, address_coin_balances})
      when type in [:realtime, :on_demand] do
    Enum.each(address_coin_balances, &broadcast_address_coin_balance/1)
  end

  def handle_event({:chain_event, :address_token_balances, type, address_token_balances})
      when type in [:realtime, :on_demand] do
    Enum.each(address_token_balances, &broadcast_address_token_balance/1)
  end

  def handle_event(
        {:chain_event, :contract_verification_result, :on_demand, {address_hash, contract_verification_result}}
      ) do
    log_broadcast_verification_results_for_address(address_hash)

    Endpoint.broadcast(
      "addresses:#{address_hash}",
      "verification_result",
      %{
        result: contract_verification_result
      }
    )
  end

  def handle_event(
        {:chain_event, :contract_verification_result, :on_demand, {address_hash, contract_verification_result, conn}}
      ) do
    log_broadcast_verification_results_for_address(address_hash)
    %{view: view, compiler: compiler} = select_contract_type_and_form_view(conn.params)

    contract_verification_result =
      case contract_verification_result do
        {:ok, _} = result ->
          result

        {:error, changeset} ->
          compiler_versions = fetch_compiler_version(compiler)

          result =
            view
            |> View.render_to_string("new.html",
              changeset: changeset,
              compiler_versions: compiler_versions,
              evm_versions: CodeCompiler.evm_versions(:solidity),
              address_hash: address_hash,
              conn: conn,
              retrying: true
            )

          {:error, result}
      end

    Endpoint.broadcast(
      "addresses:#{address_hash}",
      "verification_result",
      %{
        result: contract_verification_result
      }
    )
  end

  def handle_event({:chain_event, :block_rewards, :realtime, rewards}) do
    if Application.get_env(:block_scout_web, BlockScoutWeb.Chain)[:has_emission_funds] do
      broadcast_rewards(rewards)
    end
  end

  def handle_event({:chain_event, :blocks, :realtime, blocks}) do
    last_broadcasted_block_number = Helper.fetch_from_ets_cache(:number, :last_broadcasted_block)

    blocks
    |> Enum.sort_by(& &1.number, :asc)
    |> Enum.each(fn block ->
      broadcast_latest_block?(block, last_broadcasted_block_number)
    end)
  end

  def handle_event({:chain_event, :zkevm_confirmed_batches, :realtime, batches}) do
    batches
    |> Enum.sort_by(& &1.number, :asc)
    |> Enum.each(fn confirmed_batch ->
      Endpoint.broadcast("zkevm_batches:new_zkevm_confirmed_batch", "new_zkevm_confirmed_batch", %{
        batch: confirmed_batch
      })
    end)
  end

  def handle_event({:chain_event, :exchange_rate}) do
    exchange_rate = Market.get_coin_exchange_rate()

    market_history_data =
      case Market.fetch_recent_history() do
        [today | the_rest] -> [%{today | closing_price: exchange_rate.usd_value} | the_rest]
        data -> data
      end

    exchange_rate_with_available_supply =
      case Application.get_env(:explorer, :supply) do
        RSK ->
          %{exchange_rate | available_supply: nil, market_cap_usd: RSK.market_cap(exchange_rate)}

        _ ->
          Map.from_struct(exchange_rate)
      end

    Endpoint.broadcast("exchange_rate:new_rate", "new_rate", %{
      exchange_rate: exchange_rate_with_available_supply,
      market_history_data: Enum.map(market_history_data, fn day -> Map.take(day, [:closing_price, :date]) end)
    })
  end

  def handle_event(
        {:chain_event, :internal_transactions, :on_demand,
         [%InternalTransaction{index: 0, transaction_hash: transaction_hash}]}
      ) do
    Endpoint.broadcast("transactions:#{transaction_hash}", "raw_trace", %{raw_trace_origin: transaction_hash})
  end

  # internal transactions broadcast disabled on the indexer level, therefore it out of scope of the refactoring within https://github.com/blockscout/blockscout/pull/7474
  def handle_event({:chain_event, :internal_transactions, :realtime, internal_transactions}) do
    internal_transactions
    |> Stream.map(
      &(InternalTransaction.where_nonpending_block()
        |> Repo.get_by(transaction_hash: &1.transaction_hash, index: &1.index)
        |> Repo.preload([:from_address, :to_address, :block]))
    )
    |> Enum.each(&broadcast_internal_transaction/1)
  end

  def handle_event({:chain_event, :token_transfers, :realtime, all_token_transfers}) do
    all_token_transfers_full =
      all_token_transfers
      |> Repo.preload(
        DenormalizationHelper.extend_transaction_preload([
          :token,
          :transaction,
          from_address: [:scam_badge, :names, :smart_contract, :proxy_implementations],
          to_address: [:scam_badge, :names, :smart_contract, :proxy_implementations]
        ])
      )

    transfers_by_token = Enum.group_by(all_token_transfers_full, fn tt -> to_string(tt.token_contract_address_hash) end)

    broadcast_token_transfers_websocket_v2(all_token_transfers_full, transfers_by_token)

    for {token_contract_address_hash, token_transfers} <- transfers_by_token do
      Subscription.publish(
        Endpoint,
        token_transfers,
        token_transfers: token_contract_address_hash
      )

      token_transfers
      |> Enum.each(&broadcast_token_transfer/1)
    end
  end

  def handle_event({:chain_event, :transactions, :realtime, transactions}) do
    base_preloads = [
      :block,
      created_contract_address: [:scam_badge, :names, :smart_contract, :proxy_implementations],
      from_address: [:names, :smart_contract, :proxy_implementations],
      to_address: [:scam_badge, :names, :smart_contract, :proxy_implementations]
    ]

    preloads = if API_V2.enabled?(), do: [:token_transfers | base_preloads], else: base_preloads

    transactions
    |> Repo.preload(preloads)
    |> broadcast_transactions_websocket_v2()
    |> Enum.map(fn transaction ->
      # Disable parsing of token transfers from websocket for transaction tab because we display token transfers at a separate tab
      Map.put(transaction, :token_transfers, [])
    end)
    |> Enum.each(&broadcast_transaction/1)
  end

  def handle_event({:chain_event, :transaction_stats}) do
    today = Date.utc_today()

    [{:history_size, history_size}] =
      Application.get_env(:block_scout_web, BlockScoutWeb.Chain.TransactionHistoryChartController, {:history_size, 30})

    x_days_back = Date.add(today, -1 * history_size)

    date_range = TransactionStats.by_date_range(x_days_back, today)
    stats = Enum.map(date_range, fn item -> Map.drop(item, [:__meta__]) end)

    Endpoint.broadcast("transactions:stats", "update", %{stats: stats})
  end

  def handle_event(
        {:chain_event, :token_total_supply, :on_demand,
         [%Explorer.Chain.Token{contract_address_hash: contract_address_hash, total_supply: total_supply} = token]}
      )
      when not is_nil(total_supply) do
    Endpoint.broadcast("tokens:#{to_string(contract_address_hash)}", "token_total_supply", %{token: token})
  end

  def handle_event({:chain_event, :fetched_bytecode, :on_demand, [address_hash, fetched_bytecode]}) do
    Endpoint.broadcast("addresses:#{to_string(address_hash)}", "fetched_bytecode", %{fetched_bytecode: fetched_bytecode})
  end

  def handle_event(
        {:chain_event, :fetched_token_instance_metadata, :on_demand,
         [token_contract_address_hash_string, token_id, fetched_token_instance_metadata]}
      ) do
    Endpoint.broadcast(
      "token_instances:#{token_contract_address_hash_string}",
      "fetched_token_instance_metadata",
      %{token_id: token_id, fetched_metadata: fetched_token_instance_metadata}
    )
  end

  def handle_event({:chain_event, :changed_bytecode, :on_demand, [address_hash]}) do
    Endpoint.broadcast("addresses:#{to_string(address_hash)}", "changed_bytecode", %{})
  end

  def handle_event({:chain_event, :optimism_deposits, :realtime, deposits}) do
    broadcast_optimism_deposits(deposits, "optimism_deposits:new_deposits", "deposits")
  end

  def handle_event({:chain_event, :smart_contract_was_verified = event, :on_demand, [address_hash]}) do
    broadcast_automatic_verification_events(event, address_hash)
  end

  def handle_event({:chain_event, :smart_contract_was_not_verified = event, :on_demand, [address_hash]}) do
    broadcast_automatic_verification_events(event, address_hash)
  end

  def handle_event({:chain_event, :eth_bytecode_db_lookup_started = event, :on_demand, [address_hash]}) do
    broadcast_automatic_verification_events(event, address_hash)
  end

  def handle_event({:chain_event, :address_current_token_balances, :on_demand, address_current_token_balances}) do
    Endpoint.broadcast("addresses:#{address_current_token_balances.address_hash}", "address_current_token_balances", %{
      address_current_token_balances: address_current_token_balances.address_current_token_balances
    })
  end

  case Application.compile_env(:explorer, :chain_type) do
    :arbitrum ->
      def handle_event({:chain_event, topic, _, _} = event) when topic in @chain_type_specific_events,
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        do: BlockScoutWeb.Notifiers.Arbitrum.handle_event(event)

    _ ->
      nil
  end

  def handle_event(event) do
    Logger.warning("Unknown broadcasted event #{inspect(event)}.")
    nil
  end

  def fetch_compiler_version(compiler) do
    case CompilerVersion.fetch_versions(compiler) do
      {:ok, compiler_versions} ->
        compiler_versions

      {:error, _} ->
        []
    end
  end

  def select_contract_type_and_form_view(params) do
    verification_from_metadata_json? = check_verification_type(params, "json:metadata")

    verification_from_standard_json_input? = check_verification_type(params, "json:standard")

    verification_from_vyper? = check_verification_type(params, "vyper")

    verification_from_multi_part_files? = check_verification_type(params, "multi-part-files")

    compiler = if verification_from_vyper?, do: :vyper, else: :solc

    view =
      cond do
        verification_from_standard_json_input? -> AddressContractVerificationViaStandardJsonInputView
        verification_from_metadata_json? -> AddressContractVerificationViaJsonView
        verification_from_vyper? -> AddressContractVerificationVyperView
        verification_from_multi_part_files? -> AddressContractVerificationViaMultiPartFilesView
        true -> AddressContractVerificationViaFlattenedCodeView
      end

    %{view: view, compiler: compiler}
  end

  defp check_verification_type(params, type),
    do: Map.has_key?(params, "verification_type") && Map.get(params, "verification_type") == type

  @doc """
  Broadcast the percentage of blocks or pending block operations indexed so far.
  """
  @spec broadcast_indexed_ratio(String.t(), Decimal.t()) ::
          :ok | {:error, term()}
  def broadcast_indexed_ratio(msg, ratio) do
    Endpoint.broadcast(msg, "index_status", %{
      ratio: Decimal.to_string(ratio),
      finished: Chain.finished_indexing_from_ratio?(ratio)
    })
  end

  defp broadcast_latest_block?(block, last_broadcasted_block_number) do
    cond do
      last_broadcasted_block_number == 0 ||
        last_broadcasted_block_number == BlockNumberHelper.previous_block_number(block.number) ||
          last_broadcasted_block_number < block.number - 4 ->
        broadcast_block(block)
        :ets.insert(:last_broadcasted_block, {:number, block.number})

      last_broadcasted_block_number > BlockNumberHelper.previous_block_number(block.number) ->
        broadcast_block(block)

      true ->
        Task.start_link(fn ->
          schedule_broadcasting(block)
        end)
    end
  end

  defp schedule_broadcasting(block) do
    :timer.sleep(@check_broadcast_sequence_period)
    last_broadcasted_block_number = Helper.fetch_from_ets_cache(:number, :last_broadcasted_block)

    if last_broadcasted_block_number == BlockNumberHelper.previous_block_number(block.number) do
      broadcast_block(block)
      :ets.insert(:last_broadcasted_block, {:number, block.number})
    else
      schedule_broadcasting(block)
    end
  end

  defp broadcast_address_coin_balance(%{address_hash: address_hash, block_number: block_number}) do
    Endpoint.broadcast("addresses:#{address_hash}", "coin_balance", %{
      block_number: block_number
    })
  end

  defp broadcast_address_token_balance(%{address_hash: address_hash, block_number: block_number}) do
    Endpoint.broadcast("addresses:#{address_hash}", "token_balance", %{
      block_number: block_number
    })
  end

  defp broadcast_balance(%Address{hash: address_hash} = address) do
    Endpoint.broadcast(
      "addresses:#{address_hash}",
      "balance_update",
      %{
        address: address,
        exchange_rate: Market.get_coin_exchange_rate()
      }
    )
  end

  defp broadcast_block(block) do
    preloaded_block = Repo.preload(block, [[miner: :names], :transactions, :rewards])
    average_block_time = AverageBlockTime.average_block_time()

    Endpoint.broadcast("blocks:new_block", "new_block", %{
      block: preloaded_block,
      average_block_time: average_block_time
    })

    Endpoint.broadcast("blocks:#{to_string(block.miner_hash)}", "new_block", %{
      block: preloaded_block,
      average_block_time: average_block_time
    })
  end

  defp broadcast_rewards(rewards) do
    preloaded_rewards = Repo.preload(rewards, [:address, :block])
    emission_reward = Enum.find(preloaded_rewards, fn reward -> reward.address_type == :emission_funds end)

    preloaded_rewards_except_emission =
      Enum.reject(preloaded_rewards, fn reward -> reward.address_type == :emission_funds end)

    Enum.each(preloaded_rewards_except_emission, fn reward ->
      Endpoint.broadcast("rewards:#{to_string(reward.address_hash)}", "new_reward", %{
        emission_funds: emission_reward,
        validator: reward
      })
    end)
  end

  defp broadcast_internal_transaction(internal_transaction) do
    Endpoint.broadcast("addresses:#{internal_transaction.from_address_hash}", "internal_transaction", %{
      address: internal_transaction.from_address,
      internal_transaction: internal_transaction
    })

    if internal_transaction.to_address_hash != internal_transaction.from_address_hash do
      Endpoint.broadcast("addresses:#{internal_transaction.to_address_hash}", "internal_transaction", %{
        address: internal_transaction.to_address,
        internal_transaction: internal_transaction
      })
    end
  end

  defp broadcast_optimism_deposits(deposits, deposit_channel, event) do
    Endpoint.broadcast(deposit_channel, event, %{deposits: deposits})
  end

  defp broadcast_transactions_websocket_v2(transactions) do
    pending_transactions =
      Enum.filter(transactions, fn
        %Transaction{block_number: nil} -> true
        _ -> false
      end)

    validated_transactions =
      Enum.filter(transactions, fn
        %Transaction{block_number: nil} -> false
        _ -> true
      end)

    broadcast_transactions_websocket_v2_inner(
      pending_transactions,
      "transactions:new_pending_transaction",
      "pending_transaction"
    )

    broadcast_transactions_websocket_v2_inner(validated_transactions, "transactions:new_transaction", "transaction")

    transactions
  end

  defp broadcast_transactions_websocket_v2_inner(transactions, default_channel, event) do
    if not Enum.empty?(transactions) do
      Endpoint.broadcast(default_channel, event, %{
        transactions: transactions
      })
    end

    group_by_address_hashes_and_broadcast(transactions, event, :transactions)
  end

  defp broadcast_transaction(%Transaction{block_number: nil} = pending) do
    broadcast_transaction(pending, "transactions:new_pending_transaction", "pending_transaction")
  end

  defp broadcast_transaction(transaction) do
    broadcast_transaction(transaction, "transactions:new_transaction", "transaction")
  end

  defp broadcast_transaction(transaction, transaction_channel, event) do
    Endpoint.broadcast("transactions:#{transaction.hash}", "collated", %{})

    Endpoint.broadcast(transaction_channel, event, %{
      transaction: transaction
    })

    Endpoint.broadcast("addresses:#{transaction.from_address_hash}", event, %{
      address: transaction.from_address,
      transaction: transaction
    })

    if transaction.to_address_hash != transaction.from_address_hash do
      Endpoint.broadcast("addresses:#{transaction.to_address_hash}", event, %{
        address: transaction.to_address,
        transaction: transaction
      })
    end
  end

  defp broadcast_token_transfers_websocket_v2(tokens_transfers, transfers_by_token) do
    for {token_contract_address_hash, token_transfers} <- transfers_by_token do
      Endpoint.broadcast("tokens:#{token_contract_address_hash}", "token_transfer", %{token_transfers: token_transfers})
    end

    group_by_address_hashes_and_broadcast(tokens_transfers, "token_transfer", :token_transfers)
  end

  defp broadcast_token_transfer(token_transfer) do
    broadcast_token_transfer(token_transfer, "token_transfer")
  end

  defp broadcast_token_transfer(token_transfer, event) do
    Endpoint.broadcast("addresses:#{token_transfer.from_address_hash}", event, %{
      address: token_transfer.from_address,
      token_transfer: token_transfer
    })

    Endpoint.broadcast("tokens:#{token_transfer.token_contract_address_hash}", event, %{
      address: token_transfer.token_contract_address_hash,
      token_transfer: token_transfer
    })

    if token_transfer.to_address_hash != token_transfer.from_address_hash do
      Endpoint.broadcast("addresses:#{token_transfer.to_address_hash}", event, %{
        address: token_transfer.to_address,
        token_transfer: token_transfer
      })
    end
  end

  defp group_by_address_hashes_and_broadcast(elements, event, map_key) do
    grouped_by_from =
      elements
      |> Enum.group_by(fn el -> el.from_address_hash end)

    grouped_by_to =
      elements
      |> Enum.group_by(fn el -> el.to_address_hash end)

    grouped = Map.merge(grouped_by_to, grouped_by_from, fn _k, v1, v2 -> Enum.uniq(v1 ++ v2) end)

    for {address_hash, elements} <- grouped do
      Endpoint.broadcast("addresses:#{address_hash}", event, %{map_key => elements})
    end
  end

  defp log_broadcast_verification_results_for_address(address_hash) do
    Logger.info("Broadcast smart-contract #{address_hash} verification results")
  end

  defp log_broadcast_smart_contract_event(address_hash, event) do
    Logger.info("Broadcast smart-contract #{address_hash}: #{event}")
  end

  defp broadcast_automatic_verification_events(event, address_hash) do
    log_broadcast_smart_contract_event(address_hash, event)
    Endpoint.broadcast("addresses:#{to_string(address_hash)}", to_string(event), %{})
  end
end
