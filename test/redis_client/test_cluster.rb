# frozen_string_literal: true

require 'testing_helper'

class RedisClient
  class TestCluster
    module Mixin
      def setup
        @captured_commands = ::Middlewares::CommandCapture::CommandBuffer.new
        @redirect_count = ::Middlewares::RedirectCount::Counter.new
        @client = new_test_client
        @client.call('FLUSHDB')
        wait_for_replication
        @captured_commands.clear
        @redirect_count.clear
      end

      def teardown
        @client&.call('FLUSHDB')
        wait_for_replication
        @client&.close
        flunk(@redirect_count.get) unless @redirect_count.zero?
      end

      def test_config
        refute_nil @client.config
        refute_nil @client.config.connect_timeout
        refute_nil @client.config.read_timeout
        refute_nil @client.config.write_timeout
        refute_nil @client.config.reconnect_attempts
      end

      def test_inspect
        assert_match(/^#<RedisClient::Cluster [0-9., :]*>$/, @client.inspect)
      end

      def test_call
        assert_raises(ArgumentError) { @client.call }

        10.times do |i|
          assert_equal('OK', @client.call('SET', "key#{i}", i), "Case: SET: key#{i}")
          wait_for_replication
          assert_equal(i.to_s, @client.call('GET', "key#{i}"), "Case: GET: key#{i}")
        end

        assert(@client.call('PING') { |r| r == 'PONG' })

        assert_equal(2, @client.call('HSET', 'hash', foo: 1, bar: 2))
        wait_for_replication
        assert_equal(%w[1 2], @client.call('HMGET', 'hash', %w[foo bar]))
      end

      def test_call_once
        assert_raises(ArgumentError) { @client.call_once }

        10.times do |i|
          assert_equal('OK', @client.call_once('SET', "key#{i}", i), "Case: SET: key#{i}")
          wait_for_replication
          assert_equal(i.to_s, @client.call_once('GET', "key#{i}"), "Case: GET: key#{i}")
        end

        assert(@client.call_once('PING') { |r| r == 'PONG' })

        assert_equal(2, @client.call_once('HSET', 'hash', foo: 1, bar: 2))
        wait_for_replication
        assert_equal(%w[1 2], @client.call_once('HMGET', 'hash', %w[foo bar]))
      end

      def test_blocking_call
        skip("FIXME: this case is buggy on #{RUBY_ENGINE}") if RUBY_ENGINE == 'truffleruby' # FIXME: buggy

        assert_raises(ArgumentError) { @client.blocking_call(TEST_TIMEOUT_SEC) }

        @client.call_v(%w[RPUSH foo hello])
        @client.call_v(%w[RPUSH foo world])
        wait_for_replication

        client_side_timeout = TEST_REDIS_MAJOR_VERSION < 6 ? 2.0 : 1.5
        server_side_timeout = TEST_REDIS_MAJOR_VERSION < 6 ? '1' : '0.5'

        swap_timeout(@client, timeout: 0.1) do |client|
          assert_equal(%w[foo world], client.blocking_call(client_side_timeout, 'BRPOP', 'foo', server_side_timeout), 'Case: 1st')

          # FIXME: too flaky, just a workaround
          got = client.blocking_call(client_side_timeout, 'BRPOP', 'foo', server_side_timeout)
          if got.nil?
            assert_nil(got, 'Case: 2nd')
          else
            assert_equal(%w[foo hello], got, 'Case: 2nd')
          end

          assert_nil(client.blocking_call(client_side_timeout, 'BRPOP', 'foo', server_side_timeout), 'Case: 3rd')
          assert_raises(::RedisClient::ReadTimeoutError, 'Case: 4th') { client.blocking_call(0.1, 'BRPOP', 'foo', 0) }
        end
      end

      def test_scan
        10.times { |i| @client.call('SET', "key#{i}", i) }
        wait_for_replication
        want = (0..9).map { |i| "key#{i}" }
        got = []
        @client.scan('COUNT', '5') { |key| got << key }
        assert_equal(want, got.sort)
      end

      def test_sscan
        10.times do |i|
          10.times { |j| @client.call('SADD', "key#{i}", "member#{j}") }
          wait_for_replication
          want = (0..9).map { |j| "member#{j}" }
          got = []
          @client.sscan("key#{i}", 'COUNT', '5') { |member| got << member }
          assert_equal(want, got.sort)
        end
      end

      def test_hscan
        10.times do |i|
          10.times { |j| @client.call('HSET', "key#{i}", "field#{j}", j) }
          wait_for_replication
          want = (0..9).map { |j| ["field#{j}", j.to_s] }
          got = []
          @client.hscan("key#{i}", 'COUNT', '5') { |pair| got << pair }
          assert_equal(want, got.sort)
        end
      end

      def test_zscan
        10.times do |i|
          10.times { |j| @client.call('ZADD', "key#{i}", j, "member#{j}") }
          wait_for_replication
          want = (0..9).map { |j| ["member#{j}", j.to_s] }
          got = []
          @client.zscan("key#{i}", 'COUNT', '5') { |pair| got << pair }
          assert_equal(want, got.sort)
        end
      end

      def test_pipelined
        assert_empty([], @client.pipelined { |_| 1 + 1 })

        want = (0..9).map { 'OK' } + (1..3).to_a + %w[PONG]
        got = @client.pipelined do |pipeline|
          10.times { |i| pipeline.call('SET', "string#{i}", i) }
          3.times { |i| pipeline.call('RPUSH', 'list', i) }
          pipeline.call_once('PING')
        end
        assert_equal(want, got)

        wait_for_replication

        want = %w[PONG] + (0..9).map(&:to_s) + [%w[list 2]]
        client_side_timeout = TEST_REDIS_MAJOR_VERSION < 6 ? 1.5 : 1.0
        server_side_timeout = TEST_REDIS_MAJOR_VERSION < 6 ? '1' : '0.5'

        swap_timeout(@client, timeout: 0.1) do |client|
          got = client.pipelined do |pipeline|
            pipeline.call_once('PING')
            10.times { |i| pipeline.call('GET', "string#{i}") }
            pipeline.blocking_call(client_side_timeout, 'BRPOP', 'list', server_side_timeout)
          end

          assert_equal(want, got)
        end
      end

      def test_pipelined_with_errors
        assert_raises(RedisClient::Cluster::ErrorCollection) do
          @client.pipelined do |pipeline|
            10.times do |i|
              pipeline.call('SET', "string#{i}", i)
              pipeline.call('SET', "string#{i}", i, 'too many args')
              pipeline.call('SET', "string#{i}", i + 10)
            end
          end
        end

        wait_for_replication

        10.times { |i| assert_equal((i + 10).to_s, @client.call('GET', "string#{i}")) }
      end

      def test_pipelined_with_errors_as_is
        got = @client.pipelined(exception: false) do |pipeline|
          10.times do |i|
            pipeline.call('SET', "string#{i}", i)
            pipeline.call('SET', "string#{i}", i, 'too many args')
            pipeline.call('SET', "string#{i}", i + 10)
          end
        end

        assert_equal(30, got.size)

        10.times do |i|
          assert_equal('OK', got[(3 * i) + 0])
          assert_instance_of(::RedisClient::CommandError, got[(3 * i) + 1])
          assert_equal('OK', got[(3 * i) + 2])
        end

        wait_for_replication

        10.times { |i| assert_equal((i + 10).to_s, @client.call('GET', "string#{i}")) }
      end

      def test_pipelined_with_many_commands
        @client.pipelined { |pi| 1000.times { |i| pi.call('SET', i, i) } }
        wait_for_replication
        results = @client.pipelined { |pi| 1000.times { |i| pi.call('GET', i) } }
        results.each_with_index { |got, i| assert_equal(i.to_s, got) }
      end

      def test_transaction_with_single_key
        got = @client.multi do |t|
          t.call('SET', 'counter', '0')
          t.call('INCR', 'counter')
          t.call('INCR', 'counter')
        end

        assert_equal(['OK', 1, 2], got)

        wait_for_replication
        assert_equal('2', @client.call('GET', 'counter'))
      end

      def test_transaction_with_multiple_key
        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.multi do |t|
            t.call('SET', 'key1', '1')
            t.call('SET', 'key2', '2')
            t.call('SET', 'key3', '3')
          end
        end

        (1..3).each do |i|
          assert_nil(@client.call('GET', "key#{i}"))
        end
      end

      def test_transaction_without_block
        assert_raises(LocalJumpError) { @client.multi }
      end

      def test_transaction_with_empty_block
        @captured_commands.clear
        assert_empty(@client.multi {})
        assert_empty(@captured_commands.to_a.map(&:command).map(&:first))
      end

      def test_transaction_with_empty_block_and_watch
        @captured_commands.clear
        assert_empty(@client.multi(watch: %w[key]) {})
        assert_equal(%w[watch multi exec], @captured_commands.to_a.map(&:command).map(&:first))
      end

      def test_transaction_with_early_return_block
        @captured_commands.clear
        condition = true
        got = @client.multi do |tx|
          next if condition

          tx.call('SET', 'key', 'value')
        end

        assert_empty(got)
        assert_empty(@captured_commands.to_a.map(&:command).map(&:first))
        assert_nil(@client.call('GET', 'key'))
      end

      def test_transaction_with_early_return_block_in_watching
        @captured_commands.clear
        condition = true
        got = @client.multi(watch: %w[key]) do |tx|
          next if condition

          tx.call('SET', 'key', 'value')
        end

        assert_empty(got)
        assert_equal(%w[watch multi exec], @captured_commands.to_a.map(&:command).map(&:first))
        assert_nil(@client.call('GET', 'key'))
      end

      def test_transaction_with_only_keyless_commands
        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.multi do |t|
            t.call('ECHO', 'foo')
            t.call('ECHO', 'bar')
          end
        end
      end

      def test_transaction_with_hashtag
        got = @client.multi do |t|
          t.call('MSET', '{key}1', '1', '{key}2', '2')
          t.call('MSET', '{key}3', '3', '{key}4', '4')
        end

        assert_equal(%w[OK OK], got)

        wait_for_replication
        assert_equal(%w[1 2 3 4], @client.call('MGET', '{key}1', '{key}2', '{key}3', '{key}4'))
      end

      def test_transaction_without_hashtag
        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.multi do |t|
            t.call('MSET', 'key1', '1', 'key2', '2')
            t.call('MSET', 'key3', '3', 'key4', '4')
          end
        end

        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.multi do |t|
            t.call('MSET', 'key1', '1', 'key2', '2')
            t.call('MSET', 'key1', '1', 'key3', '3')
            t.call('MSET', 'key1', '1', 'key4', '4')
          end
        end

        (1..4).each do |i|
          assert_nil(@client.call('GET', "key#{i}"))
        end
      end

      def test_transaction_with_watch
        @client.call('MSET', '{key}1', '0', '{key}2', '0')

        got = @client.multi(watch: %w[{key}1 {key}2]) do |tx|
          tx.call('ECHO', 'START')
          tx.call('SET', '{key}1', '1')
          tx.call('SET', '{key}2', '2')
          tx.call('ECHO', 'FINISH')
        end

        assert_equal(%w[START OK OK FINISH], got)

        wait_for_replication
        assert_equal(%w[1 2], @client.call('MGET', '{key}1', '{key}2'))
      end

      def test_transaction_with_unsafe_watch
        @client.call('MSET', '{key}1', '0', '{key}2', '0')

        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.multi(watch: %w[key1 key2]) do |tx|
            tx.call('SET', '{key}1', '1')
            tx.call('SET', '{key}2', '2')
          end
        end

        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.multi(watch: %w[{hey}1 {hey}2]) do |tx|
            tx.call('SET', '{key}1', '1')
            tx.call('SET', '{key}2', '2')
          end
        end

        wait_for_replication
        assert_equal(%w[0 0], @client.call('MGET', '{key}1', '{key}2'))
      end

      def test_transaction_with_meaningless_watch
        @client.call('MSET', '{key}1', '0', '{key}2', '0')

        got = @client.multi(watch: %w[{key}3 {key}4]) do |tx|
          tx.call('ECHO', 'START')
          tx.call('SET', '{key}1', '1')
          tx.call('SET', '{key}2', '2')
          tx.call('ECHO', 'FINISH')
        end

        assert_equal(%w[START OK OK FINISH], got)

        wait_for_replication
        assert_equal(%w[1 2], @client.call('MGET', '{key}1', '{key}2'))
      end

      def test_transaction_does_not_pointlessly_unwatch_on_success
        @client.call('MSET', '{key}1', '0', '{key}2', '0')

        @captured_commands.clear
        @client.multi(watch: %w[{key}1 {key}2]) do |tx|
          tx.call('SET', '{key}1', '1')
          tx.call('SET', '{key}2', '2')
        end

        assert_equal(%w[watch multi SET SET exec], @captured_commands.to_a.map(&:command).map(&:first))

        wait_for_replication
        assert_equal(%w[1 2], @client.call('MGET', '{key}1', '{key}2'))
      end

      def test_transaction_unwatches_on_error
        test_error = Class.new(StandardError)

        @captured_commands.clear
        assert_raises(test_error) do
          @client.multi(watch: %w[{key}1 {key}2]) do
            raise test_error, 'error!'
          end
        end

        assert_equal(%w[watch unwatch], @captured_commands.to_a.map(&:command).map(&:first))
      end

      def test_transaction_does_not_unwatch_on_connection_error
        @captured_commands.clear
        assert_raises(RedisClient::ConnectionError) do
          @client.multi(watch: %w[{key}1 {key}2]) do |tx|
            tx.call('SET', '{key}1', 'x')
            tx.call('QUIT')
          end
        end

        command_list = @captured_commands.to_a.map(&:command).map(&:first)
        assert_includes(command_list, 'watch')
        refute_includes(command_list, 'unwatch')
      end

      def test_transaction_does_not_retry_without_rewatching
        client2 = new_test_client(middlewares: nil)

        @client.call('SET', 'key', 'original_value')

        assert_raises(RedisClient::ConnectionError) do
          @client.multi(watch: %w[key]) do |tx|
            # Simulate all the connections closing behind the router's back
            # Sending QUIT to redis makes the server side close the connection (and the client
            # side thus get a RedisClient::ConnectionError)
            node = @client.instance_variable_get(:@router).instance_variable_get(:@node)
            node.clients.each do |conn|
              conn.with(&:close)
            end

            # Now the second client sets the value, which should make this watch invalid
            client2.call('SET', 'key', 'client2_value')

            tx.call('SET', 'key', '@client_value')
            # Committing this transaction will fail, not silently reconnect (without the watch!)
          end
        end

        # The transaction did not commit.
        wait_for_replication
        assert_equal('client2_value', @client.call('GET', 'key'))
      end

      def test_transaction_with_watch_retries_block
        client2 = new_test_client(middlewares: nil)
        call_count = 0

        @client.call('SET', 'key', 'original_value')

        @client.multi(watch: %w[key]) do |tx|
          if call_count == 0
            # Simulate all the connections closing behind the router's back
            # Sending QUIT to redis makes the server side close the connection (and the client
            # side thus get a RedisClient::ConnectionError)
            node = @client.instance_variable_get(:@router).instance_variable_get(:@node)
            node.clients.each do |conn|
              conn.with(&:close)
            end

            # Now the second client sets the value, which should make this watch invalid
            client2.call('SET', 'key', 'client2_value')
          end
          call_count += 1

          tx.call('SET', 'key', "@client_value_#{call_count}")
        end

        # The transaction did commit (but it was the second time)
        wait_for_replication
        assert_equal('@client_value_2', @client.call('GET', 'key'))
        assert_equal(2, call_count)
      end

      def test_transaction_with_error
        @client.call('SET', 'key1', 'x')

        assert_raises(::RedisClient::CommandError) do
          @client.multi do |tx|
            tx.call('SET', 'key1', 'aaa')
            tx.call('MYBAD', 'key1', 'bbb')
          end
        end

        wait_for_replication
        assert_equal('x', @client.call('GET', 'key1'))
      end

      def test_transaction_without_error_during_queueing
        @client.call('SET', 'key1', 'x')

        assert_raises(::RedisClient::CommandError) do
          @client.multi do |tx|
            tx.call('SET', 'key1', 'aaa')
            tx.call('INCR', 'key1')
          end
        end

        wait_for_replication
        assert_equal('aaa', @client.call('GET', 'key1'))
      end

      def test_transaction_with_block
        @client.call('MSET', '{key}1', 'a', '{key}2', 'b', '{key}3', 'c')

        got = @client.multi do |tx|
          tx.call('GET', '{key}1') { |x| "#{x}aa" }
          tx.call('GET', '{key}2') { |x| "#{x}bb" }
          tx.call('GET', '{key}3') { |x| "#{x}cc" }
        end

        assert_equal(%w[aaa bbb ccc], got)

        got = @client.multi(watch: %w[{key}1 {key}2 {key}3]) do |tx|
          tx.call('GET', '{key}1') { |x| "#{x}11" }
          tx.call('GET', '{key}2') { |x| "#{x}22" }
          tx.call('GET', '{key}3') { |x| "#{x}33" }
        end

        assert_equal(%w[a11 b22 c33], got)
      end

      def test_transaction_in_race_condition
        @client.call('MSET', '{key}1', '1', '{key}2', '2')

        another = Fiber.new do
          cli = new_test_client(middlewares: nil)
          cli.call('MSET', '{key}1', '3', '{key}2', '4')
          cli.close
          Fiber.yield
        end

        got = @client.multi(watch: %w[{key}1 {key}2]) do |tx|
          another.resume
          v1 = @client.call('GET', '{key}1')
          v2 = @client.call('GET', '{key}2')
          tx.call('SET', '{key}1', v2)
          tx.call('SET', '{key}2', v1)
        end

        assert_nil(got)

        wait_for_replication
        assert_equal(%w[3 4], @client.call('MGET', '{key}1', '{key}2'))
      end

      def test_transaction_with_dedicated_watch_command
        @client.call('MSET', '{key}1', '0', '{key}2', '0')

        got = @client.call('WATCH', '{key}1', '{key}2') do |tx|
          tx.call('ECHO', 'START')
          tx.call('SET', '{key}1', '1')
          tx.call('SET', '{key}2', '2')
          tx.call('ECHO', 'FINISH')
        end

        assert_equal(%w[START OK OK FINISH], got)

        wait_for_replication
        assert_equal(%w[1 2], @client.call('MGET', '{key}1', '{key}2'))
      end

      def test_transaction_with_dedicated_watch_command_without_block
        assert_raises(::RedisClient::Cluster::Transaction::ConsistencyError) do
          @client.call('WATCH', '{key}1', '{key}2')
        end
      end

      def test_pubsub_without_subscription
        pubsub = @client.pubsub
        assert_nil(pubsub.next_event(0.01))
        pubsub.close
      end

      def test_pubsub_with_wrong_command
        pubsub = @client.pubsub
        assert_nil(pubsub.call('SUBWAY'))
        assert_nil(pubsub.call_v(%w[SUBSCRIBE]))
        assert_raises(::RedisClient::CommandError, 'unknown command') { pubsub.next_event }
        assert_raises(::RedisClient::CommandError, 'wrong number of arguments') { pubsub.next_event }
        assert_nil(pubsub.next_event(0.01))
        pubsub.close
      end

      def test_global_pubsub
        sub = Fiber.new do |pubsub|
          channel = 'my-global-channel'
          pubsub.call('SUBSCRIBE', channel)
          assert_equal(['subscribe', channel, 1], pubsub.next_event(TEST_TIMEOUT_SEC))
          Fiber.yield(channel)
          Fiber.yield(pubsub.next_event(TEST_TIMEOUT_SEC))
          pubsub.call('UNSUBSCRIBE')
          pubsub.close
        end

        channel = sub.resume(@client.pubsub)
        publish_messages { |cli| cli.call('PUBLISH', channel, 'hello global world') }
        assert_equal(['message', channel, 'hello global world'], sub.resume)
      end

      def test_global_pubsub_without_timeout
        sub = Fiber.new do |pubsub|
          pubsub.call('SUBSCRIBE', 'my-global-not-published-channel', 'my-global-published-channel')
          want = [%w[subscribe my-global-not-published-channel], %w[subscribe my-global-published-channel]]
          got = collect_messages(pubsub, size: 2, timeout: nil).map { |e| e.take(2) }.sort_by { |e| e[1].to_s }
          assert_equal(want, got)
          Fiber.yield('my-global-published-channel')
          Fiber.yield(collect_messages(pubsub, size: 1, timeout: nil).first)
          pubsub.call('UNSUBSCRIBE')
          pubsub.close
        end

        channel = sub.resume(@client.pubsub)
        publish_messages { |cli| cli.call('PUBLISH', channel, 'hello global published world') }
        assert_equal(['message', channel, 'hello global published world'], sub.resume)
      end

      def test_global_pubsub_with_multiple_channels
        sub = Fiber.new do |pubsub|
          pubsub.call('SUBSCRIBE', *Array.new(10) { |i| "g-chan#{i}" })
          got = collect_messages(pubsub, size: 10).sort_by { |e| e[1].to_s }
          10.times { |i| assert_equal(['subscribe', "g-chan#{i}", i + 1], got[i]) }
          Fiber.yield
          Fiber.yield(collect_messages(pubsub, size: 10))
          pubsub.call('UNSUBSCRIBE')
          pubsub.close
        end

        sub.resume(@client.pubsub)
        publish_messages { |cli| cli.pipelined { |pi| 10.times { |i| pi.call('PUBLISH', "g-chan#{i}", i) } } }
        got = sub.resume.sort_by { |e| e[1].to_s }
        10.times { |i| assert_equal(['message', "g-chan#{i}", i.to_s], got[i]) }
      end

      def test_sharded_pubsub
        if TEST_REDIS_MAJOR_VERSION < 7
          skip('Sharded Pub/Sub is supported by Redis 7+.')
          return
        end

        sub = Fiber.new do |pubsub|
          channel = 'my-sharded-channel'
          pubsub.call('SSUBSCRIBE', channel)
          assert_equal(['ssubscribe', channel, 1], pubsub.next_event(TEST_TIMEOUT_SEC))
          Fiber.yield(channel)
          Fiber.yield(pubsub.next_event(TEST_TIMEOUT_SEC))
          pubsub.call('SUNSUBSCRIBE')
          pubsub.close
        end

        channel = sub.resume(@client.pubsub)
        publish_messages { |cli| cli.call('SPUBLISH', channel, 'hello sharded world') }
        assert_equal(['smessage', channel, 'hello sharded world'], sub.resume)
      end

      def test_sharded_pubsub_without_timeout
        if TEST_REDIS_MAJOR_VERSION < 7
          skip('Sharded Pub/Sub is supported by Redis 7+.')
          return
        end

        sub = Fiber.new do |pubsub|
          pubsub.call('SSUBSCRIBE', 'my-sharded-not-published-channel')
          pubsub.call('SSUBSCRIBE', 'my-sharded-published-channel')
          want = [%w[ssubscribe my-sharded-not-published-channel], %w[ssubscribe my-sharded-published-channel]]
          got = collect_messages(pubsub, size: 2, timeout: nil).map { |e| e.take(2) }.sort_by { |e| e[1].to_s }
          assert_equal(want, got)
          Fiber.yield('my-sharded-published-channel')
          Fiber.yield(collect_messages(pubsub, size: 1, timeout: nil).first)
          pubsub.call('SUNSUBSCRIBE')
          pubsub.close
        end

        channel = sub.resume(@client.pubsub)
        publish_messages { |cli| cli.call('SPUBLISH', channel, 'hello sharded published world') }
        assert_equal(['smessage', channel, 'hello sharded published world'], sub.resume)
      end

      def test_sharded_pubsub_with_multiple_channels
        if TEST_REDIS_MAJOR_VERSION < 7
          skip('Sharded Pub/Sub is supported by Redis 7+.')
          return
        end

        sub = Fiber.new do |pubsub|
          10.times { |i| pubsub.call('SSUBSCRIBE', "s-chan#{i}") }
          got = collect_messages(pubsub, size: 10).sort_by { |e| e[1].to_s }
          10.times { |i| assert_equal(['ssubscribe', "s-chan#{i}"], got[i].take(2)) }
          Fiber.yield
          Fiber.yield(collect_messages(pubsub, size: 10))
          pubsub.call('SUNSUBSCRIBE')
          pubsub.close
        end

        sub.resume(@client.pubsub)
        publish_messages { |cli| cli.pipelined { |pi| 10.times { |i| pi.call('SPUBLISH', "s-chan#{i}", i) } } }
        got = sub.resume.sort_by { |e| e[1].to_s }
        10.times { |i| assert_equal(['smessage', "s-chan#{i}", i.to_s], got[i]) }
      end

      def test_other_pubsub_commands
        assert_instance_of(Array, @client.call('pubsub', 'channels'))
        assert_instance_of(Integer, @client.call('pubsub', 'numpat'))
        assert_instance_of(Hash, @client.call('pubsub', 'numsub'))
        assert_instance_of(Array, @client.call('pubsub', 'shardchannels')) if TEST_REDIS_MAJOR_VERSION >= 7
        assert_instance_of(Hash, @client.call('pubsub', 'shardnumsub')) if TEST_REDIS_MAJOR_VERSION >= 7
        ps = @client.pubsub
        assert_nil(ps.call('unsubscribe'))
        assert_nil(ps.call('punsubscribe'))
        assert_nil(ps.call('sunsubscribe')) if TEST_REDIS_MAJOR_VERSION >= 7
        ps.close
      end

      def test_stream_commands
        @client.call('xadd', '{stream}1', '*', 'mesage', 'foo')
        @client.call('xadd', '{stream}1', '*', 'mesage', 'bar')
        @client.call('xadd', '{stream}2', '*', 'mesage', 'baz')
        @client.call('xadd', '{stream}2', '*', 'mesage', 'zap')
        wait_for_replication

        consumer = new_test_client
        got = consumer.call('xread', 'streams', '{stream}1', '{stream}2', '0', '0')
        consumer.close

        got = got.to_h if TEST_REDIS_MAJOR_VERSION < 6

        assert_equal('foo', got.fetch('{stream}1')[0][1][1])
        assert_equal('bar', got.fetch('{stream}1')[1][1][1])
        assert_equal('baz', got.fetch('{stream}2')[0][1][1])
        assert_equal('zap', got.fetch('{stream}2')[1][1][1])
      end

      def test_stream_group_commands
        @client.call('xadd', '{stream}1', '*', 'task', 'data1')
        @client.call('xadd', '{stream}1', '*', 'task', 'data2')
        @client.call('xgroup', 'create', '{stream}1', 'worker', '0')
        wait_for_replication

        consumer1 = new_test_client
        consumer2 = new_test_client
        got1 = consumer1.call('xreadgroup', 'group', 'worker', 'consumer1', 'count', '1', 'streams', '{stream}1', '>')
        got2 = consumer2.call('xreadgroup', 'group', 'worker', 'consumer2', 'count', '1', 'streams', '{stream}1', '>')
        consumer1.close
        consumer2.close

        if TEST_REDIS_MAJOR_VERSION < 6
          got1 = got1.to_h
          got2 = got2.to_h
        end

        assert_equal('data1', got1.fetch('{stream}1')[0][1][1])
        assert_equal('data2', got2.fetch('{stream}1')[0][1][1])
      end

      def test_with_method
        assert_raises(NotImplementedError) { @client.with }
      end

      def test_dedicated_multiple_keys_command
        [
          { command: %w[MSET key1 val1], want: 'OK', wait: true },
          { command: %w[MGET key1], want: %w[val1] },
          { command: %w[DEL key1], want: 1, wait: true },
          { command: %w[MSET {key}1 val1 {key}2 val2], want: 'OK', wait: true },
          { command: %w[MGET {key}1 {key}2], want: %w[val1 val2] },
          { command: %w[DEL {key}1 {key}2], want: 2, wait: true },
          { command: %w[MSET key1 val1 key2 val2], want: 'OK', wait: true },
          { command: %w[MGET key1 key2], want: %w[val1 val2] },
          { command: %w[DEL key1 key2], want: 2, wait: true },
          { command: %w[MSET key1 val1 key2 val2], block: ->(r) { "#{r}!" }, want: 'OK!', wait: true },
          { command: %w[MGET key1 key2], block: ->(r) { r.map { |e| "#{e}!" } }, want: %w[val1! val2!] },
          { command: %w[DEL key1 key2], block: ->(r) { r == 2 }, want: true, wait: true }
        ].each_with_index do |c, i|
          block = c.key?(:block) ? c.fetch(:block) : nil
          assert_equal(c.fetch(:want), @client.call_v(c.fetch(:command), &block), i + 1)
          wait_for_replication if c.fetch(:wait, false)
        end
      end

      def test_dedicated_commands
        10.times { |i| @client.call('SET', "key#{i}", i) }
        wait_for_replication
        [
          { command: %w[ACL HELP], is_a: Array, supported_redis_version: 6 },
          { command: ['WAIT', TEST_REPLICA_SIZE, '1'], is_a: Integer },
          { command: %w[KEYS *], want: (0..9).map { |i| "key#{i}" } },
          { command: %w[DBSIZE], want: (0..9).size },
          { command: %w[SCAN], is_a: Array },
          { command: %w[LASTSAVE], is_a: Array },
          { command: %w[ROLE], is_a: Array },
          { command: %w[CONFIG RESETSTAT], want: 'OK' },
          { command: %w[CONFIG GET maxmemory], is_a: TEST_REDIS_MAJOR_VERSION < 6 ? Array : Hash },
          {
            command: %w[CLIENT LIST],
            blk: ->(r) { r.lines("\n", chomp: true).map(&:split).map { |e| Hash[e.map { |x| x.split('=') }] } },
            is_a: Array
          },
          { command: %w[CLIENT PAUSE 100], want: 'OK' },
          { command: %w[CLIENT INFO], is_a: String, supported_redis_version: 6 },
          { command: %w[CLUSTER SET-CONFIG-EPOCH 0], error: ::RedisClient::Cluster::OrchestrationCommandNotSupported },
          { command: %w[CLUSTER SAVECONFIG], want: 'OK' },
          { command: %w[CLUSTER GETKEYSINSLOT 13252 1], want: %w[key0] },
          { command: %w[CLUSTER NODES], is_a: String },
          { command: %w[READONLY], error: ::RedisClient::Cluster::OrchestrationCommandNotSupported },
          { command: %w[MEMORY STATS], is_a: Array },
          { command: %w[MEMORY PURGE], want: 'OK' },
          { command: %w[MEMORY USAGE key0], is_a: Integer },
          { command: %w[SCRIPT DEBUG NO], want: 'OK' },
          { command: %w[SCRIPT FLUSH], want: 'OK' },
          { command: %w[SCRIPT EXISTS b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c], want: [0] },
          { command: %w[SCRIPT EXISTS 5b9fb3410653a731f8ddfeff39a0c061 31b6de18e43fe980ed07d8b0f5a8cabe], want: [0, 0] },
          {
            command: %w[SCRIPT EXISTS b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c],
            blk: ->(reply) { reply.map { |r| !r.zero? } },
            want: [false]
          },
          {
            command: %w[SCRIPT EXISTS 5b9fb3410653a731f8ddfeff39a0c061 31b6de18e43fe980ed07d8b0f5a8cabe],
            blk: ->(reply) { reply.map { |r| !r.zero? } },
            want: [false, false]
          },
          { command: %w[PUBSUB CHANNELS test-channel*], want: [] },
          { command: %w[PUBSUB NUMSUB test-channel], want: { 'test-channel' => 0 } },
          { command: %w[PUBSUB NUMPAT], want: 0 },
          { command: %w[PUBSUB HELP], is_a: Array },
          { command: %w[MULTI], error: ::RedisClient::Cluster::AmbiguousNodeError },
          { command: %w[FLUSHDB], want: 'OK' }
        ].each do |c|
          next if c.key?(:supported_redis_version) && c[:supported_redis_version] > TEST_REDIS_MAJOR_VERSION

          msg = "Case: #{c[:command].join(' ')}"
          got = -> { @client.call_v(c[:command], &c[:blk]) }
          if c.key?(:error)
            assert_raises(c[:error], msg, &got)
          elsif c.key?(:is_a)
            assert_instance_of(c[:is_a], got.call, msg)
          else
            assert_equal(c[:want], got.call, msg)
          end
        end
      end

      def test_compatibility_with_redis_gem
        assert_equal('OK', @client.set('foo', 100))
        wait_for_replication
        assert_equal('100', @client.get('foo'))
        assert_raises(NoMethodError) { @client.densaugeo('1m') }
      end

      def test_circuit_breakers
        cli = ::RedisClient.cluster(
          nodes: TEST_NODE_URIS,
          fixed_hostname: TEST_FIXED_HOSTNAME,
          # This option is important - need to make sure that the reloads happen on different connections
          # to the timeouts, so that they don't count against the circuit breaker (they'll have their own breakers).
          connect_with_original_config: true,
          **TEST_GENERIC_OPTIONS.merge(
            circuit_breaker: {
              # Also important - the retry_count on resharding errors is set to 3, so we have to allow at lest
              # that many errors to avoid tripping the breaker in the first call.
              error_threshold: 4,
              error_timeout: 60,
              success_threshold: 10
            }
          )
        ).new_client

        cli.call('echo', 'init')

        swap_timeout(cli, timeout: 0.1) do |c|
          assert_raises(::RedisClient::ReadTimeoutError) { c.blocking_call(0.1, 'BRPOP', 'foo', 0) }
          assert_raises(::RedisClient::CircuitBreaker::OpenCircuitError) { c.blocking_call(0.1, 'BRPOP', 'foo', 0) }
        end

        cli&.close
      end

      def test_only_reshards_own_errors
        slot = ::RedisClient::Cluster::KeySlotConverter.convert('testkey')
        router = @client.instance_variable_get(:@router)
        correct_primary_key = router.find_node_key_by_key('testkey', primary: true)
        broken_primary_key = (router.node_keys - [correct_primary_key]).first

        client1 = new_test_client(
          middlewares: [
            ::RedisClient::Cluster::ErrorIdentification::Middleware
          ]
        )

        client2 = new_test_client(
          middlewares: [
            ::RedisClient::Cluster::ErrorIdentification::Middleware,
            ::Middlewares::RedirectFake
          ],
          custom: {
            redirect_fake: ::Middlewares::RedirectFake::Setting.new(
              slot: slot, to: broken_primary_key, command: %w[set testkey client2]
            )
          }
        )

        assert_raises(RedisClient::CommandError) do
          client1.call('set', 'testkey', 'client1') do |got|
            assert_equal('OK', got)
            client2.call('set', 'testkey', 'client2')
          end
        end

        # The exception should not have causes client1 to update its shard mappings, because it didn't
        # come from a RedisClient instance that client1 knows about.
        assert_equal(
          correct_primary_key,
          client1.instance_variable_get(:@router).find_node_key_by_key('testkey', primary: true)
        )

        client1.close
        client2.close
      end

      def test_initialization_delayed
        config = ::RedisClient::ClusterConfig.new(nodes: 'redis://127.0.0.1:11211')
        client = ::RedisClient::Cluster.new(config)
        assert_instance_of(::RedisClient::Cluster, client)
        assert_raises(RedisClient::Cluster::InitialSetupError) { client.call('PING') }
      end

      private

      def wait_for_replication
        client_side_timeout = TEST_TIMEOUT_SEC + 1.0
        server_side_timeout = (TEST_TIMEOUT_SEC * 1000).to_i
        swap_timeout(@client, timeout: 0.1) do |client|
          client&.blocking_call(client_side_timeout, 'WAIT', TEST_REPLICA_SIZE, server_side_timeout)
        rescue RedisClient::Cluster::ErrorCollection => e
          # FIXME: flaky in jruby on #test_pubsub_with_wrong_command
          raise unless e.errors.values.all? { |err| err.is_a?(::RedisClient::ConnectionError) }
        end
      end

      def collect_messages(pubsub, size:, max_attempts: 30, timeout: 1.0)
        messages = []
        attempts = 0
        loop do
          attempts += 1
          break if attempts > max_attempts

          reply = pubsub.next_event(timeout)
          break if reply.nil?

          messages << reply
          break messages if messages.size == size
        end
      end

      def publish_messages
        client = new_test_client(middlewares: nil)
        yield client
        client.close
      end

      def hiredis_used?
        ::RedisClient.const_defined?(:HiredisConnection) &&
          ::RedisClient.default_driver == ::RedisClient::HiredisConnection
      end
    end

    class PrimaryOnly < TestingWrapper
      include Mixin

      def new_test_client(
        custom: { captured_commands: @captured_commands, redirect_count: @redirect_count },
        middlewares: [::Middlewares::CommandCapture, ::Middlewares::RedirectCount],
        **opts
      )
        config = ::RedisClient::ClusterConfig.new(
          nodes: TEST_NODE_URIS,
          fixed_hostname: TEST_FIXED_HOSTNAME,
          slow_command_timeout: TEST_TIMEOUT_SEC,
          middlewares: middlewares,
          custom: custom,
          **TEST_GENERIC_OPTIONS,
          **opts
        )
        ::RedisClient::Cluster.new(config)
      end
    end

    class ScaleReadRandom < TestingWrapper
      include Mixin

      def new_test_client(
        custom: { captured_commands: @captured_commands, redirect_count: @redirect_count },
        middlewares: [::Middlewares::CommandCapture, ::Middlewares::RedirectCount],
        **opts
      )
        config = ::RedisClient::ClusterConfig.new(
          nodes: TEST_NODE_URIS,
          replica: true,
          replica_affinity: :random,
          fixed_hostname: TEST_FIXED_HOSTNAME,
          slow_command_timeout: TEST_TIMEOUT_SEC,
          middlewares: middlewares,
          custom: custom,
          **TEST_GENERIC_OPTIONS,
          **opts
        )
        ::RedisClient::Cluster.new(config)
      end
    end

    class ScaleReadRandomWithPrimary < TestingWrapper
      include Mixin

      def new_test_client(
        custom: { captured_commands: @captured_commands, redirect_count: @redirect_count },
        middlewares: [::Middlewares::CommandCapture, ::Middlewares::RedirectCount],
        **opts
      )
        config = ::RedisClient::ClusterConfig.new(
          nodes: TEST_NODE_URIS,
          replica: true,
          replica_affinity: :random_with_primary,
          fixed_hostname: TEST_FIXED_HOSTNAME,
          slow_command_timeout: TEST_TIMEOUT_SEC,
          middlewares: middlewares,
          custom: custom,
          **TEST_GENERIC_OPTIONS,
          **opts
        )
        ::RedisClient::Cluster.new(config)
      end
    end

    class ScaleReadLatency < TestingWrapper
      include Mixin

      def new_test_client(
        custom: { captured_commands: @captured_commands, redirect_count: @redirect_count },
        middlewares: [::Middlewares::CommandCapture, ::Middlewares::RedirectCount],
        **opts
      )
        config = ::RedisClient::ClusterConfig.new(
          nodes: TEST_NODE_URIS,
          replica: true,
          replica_affinity: :latency,
          fixed_hostname: TEST_FIXED_HOSTNAME,
          slow_command_timeout: TEST_TIMEOUT_SEC,
          middlewares: middlewares,
          custom: custom,
          **TEST_GENERIC_OPTIONS,
          **opts
        )
        ::RedisClient::Cluster.new(config)
      end
    end

    class Pooled < TestingWrapper
      include Mixin

      def new_test_client(
        custom: { captured_commands: @captured_commands, redirect_count: @redirect_count },
        middlewares: [::Middlewares::CommandCapture, ::Middlewares::RedirectCount],
        **opts
      )
        config = ::RedisClient::ClusterConfig.new(
          nodes: TEST_NODE_URIS,
          fixed_hostname: TEST_FIXED_HOSTNAME,
          slow_command_timeout: TEST_TIMEOUT_SEC,
          middlewares: middlewares,
          custom: custom,
          **TEST_GENERIC_OPTIONS,
          **opts
        )
        ::RedisClient::Cluster.new(config, pool: { timeout: TEST_TIMEOUT_SEC, size: 2 })
      end
    end
  end
end
