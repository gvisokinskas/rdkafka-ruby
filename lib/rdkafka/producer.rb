# frozen_string_literal: true

require "objspace"

module Rdkafka
  # A producer for Kafka messages. To create a producer set up a {Config} and call {Config#producer producer} on that.
  class Producer
    # @private
    # Returns the current delivery callback, by default this is nil.
    #
    # @return [Proc, nil]
    attr_reader :delivery_callback

    # @private
    # Returns the number of arguments accepted by the callback, by default this is nil.
    #
    # @return [Integer, nil]
    attr_reader :delivery_callback_arity

    # @private
    def initialize(client, partitioner_name)
      @client = client
      @partitioner_name = partitioner_name || "consistent_random"

      # Makes sure, that the producer gets closed before it gets GCed by Ruby
      ObjectSpace.define_finalizer(self, client.finalizer)
    end

    # Set a callback that will be called every time a message is successfully produced.
    # The callback is called with a {DeliveryReport} and {DeliveryHandle}
    #
    # @param callback [Proc, #call] The callback
    #
    # @return [nil]
    def delivery_callback=(callback)
      raise TypeError.new("Callback has to be callable") unless callback.respond_to?(:call)
      @delivery_callback = callback
      @delivery_callback_arity = arity(callback)
    end

    # Close this producer and wait for the internal poll queue to empty.
    def close
      ObjectSpace.undefine_finalizer(self)

      @client.close
    end

    # Partition count for a given topic.
    # NOTE: If 'allow.auto.create.topics' is set to true in the broker, the topic will be auto-created after returning nil.
    #
    # @param topic [String] The topic name.
    #
    # @return partition count [Integer,nil]
    #
    def partition_count(topic)
      closed_producer_check(__method__)
      Rdkafka::Metadata.new(@client.native, topic).topics&.first[:partition_count]
    end

    # Produces a message to a Kafka topic. The message is added to rdkafka's queue, call {DeliveryHandle#wait wait} on the returned delivery handle to make sure it is delivered.
    #
    # When no partition is specified the underlying Kafka library picks a partition based on the key. If no key is specified, a random partition will be used.
    # When a timestamp is provided this is used instead of the auto-generated timestamp.
    #
    # @param topic [String] The topic to produce to
    # @param payload [String,nil] The message's payload
    # @param key [String, nil] The message's key
    # @param partition [Integer,nil] Optional partition to produce to
    # @param partition_key [String, nil] Optional partition key based on which partition assignment can happen
    # @param timestamp [Time,Integer,nil] Optional timestamp of this message. Integer timestamp is in milliseconds since Jan 1 1970.
    # @param headers [Hash<String,String>] Optional message headers
    #
    # @raise [RdkafkaError] When adding the message to rdkafka's queue failed
    #
    # @return [DeliveryHandle] Delivery handle that can be used to wait for the result of producing this message
    def produce(topic:, payload: nil, key: nil, partition: nil, partition_key: nil, timestamp: nil, headers: nil)
      closed_producer_check(__method__)

      # Start by checking and converting the input

      # Get payload length
      payload_size = if payload.nil?
                       0
                     else
                       payload.bytesize
                     end

      # Get key length
      key_size = if key.nil?
                   0
                 else
                   key.bytesize
                 end

      if partition_key
        partition_count = partition_count(topic)
        # If the topic is not present, set to -1
        partition = Rdkafka::Bindings.partitioner(partition_key, partition_count, @partitioner_name) if partition_count
      end

      # If partition is nil, use -1 to let librdafka set the partition randomly or
      # based on the key when present.
      partition ||= -1

      # If timestamp is nil use 0 and let Kafka set one. If an integer or time
      # use it.
      raw_timestamp = if timestamp.nil?
                        0
                      elsif timestamp.is_a?(Integer)
                        timestamp
                      elsif timestamp.is_a?(Time)
                        (timestamp.to_i * 1000) + (timestamp.usec / 1000)
                      else
                        raise TypeError.new("Timestamp has to be nil, an Integer or a Time")
                      end

      delivery_handle = DeliveryHandle.new
      delivery_handle[:pending] = true
      delivery_handle[:response] = -1
      delivery_handle[:partition] = -1
      delivery_handle[:offset] = -1
      DeliveryHandle.register(delivery_handle)

      args = [
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_TOPIC, :string, topic,
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_MSGFLAGS, :int, Rdkafka::Bindings::RD_KAFKA_MSG_F_COPY,
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_VALUE, :buffer_in, payload, :size_t, payload_size,
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_KEY, :buffer_in, key, :size_t, key_size,
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_PARTITION, :int32, partition,
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_TIMESTAMP, :int64, raw_timestamp,
        :int, Rdkafka::Bindings::RD_KAFKA_VTYPE_OPAQUE, :pointer, delivery_handle,
      ]

      if headers
        headers.each do |key0, value0|
          key = key0.to_s
          value = value0.to_s
          args << :int << Rdkafka::Bindings::RD_KAFKA_VTYPE_HEADER
          args << :string << key
          args << :pointer << value
          args << :size_t << value.bytes.size
        end
      end

      args << :int << Rdkafka::Bindings::RD_KAFKA_VTYPE_END

      # Produce the message
      response = Rdkafka::Bindings.rd_kafka_producev(
        @client.native,
        *args
      )

      # Raise error if the produce call was not successful
      if response != 0
        DeliveryHandle.remove(delivery_handle.to_ptr.address)
        raise RdkafkaError.new(response)
      end

      delivery_handle
    end

    # @private
    def call_delivery_callback(delivery_report, delivery_handle)
      return unless @delivery_callback

      args = [delivery_report, delivery_handle].take(@delivery_callback_arity)
      @delivery_callback.call(*args)
    end

    def arity(callback)
      return callback.arity if callback.respond_to?(:arity)

      callback.method(:call).arity
    end

    def closed_producer_check(method)
      raise Rdkafka::ClosedProducerError.new(method) if @client.closed?
    end
  end
end
