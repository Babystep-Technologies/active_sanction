# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"

module ActiveSanction
  class Sync
    # What one source did in one sync run, and what is stored for it now.
    #
    #   result.source        # => :ofac_sdn
    #   result.status        # => :updated, :unchanged or :failed
    #   result.record_count  # => 19015
    #   result.duration      # => 12.41
    #   result.age           # => 0
    #
    # Three statuses, and the distinction between the last two is the whole
    # point of isolating sources from each other:
    #
    #   :updated    a new list version was parsed and stored
    #   :unchanged  the publisher confirmed the copy we hold; nothing was written
    #   :failed     something raised; **the previous snapshot was kept**
    #
    # ### A failed source still says what is being screened against
    #
    # `checksum`, `record_count`, `fetched_at` and `age` describe the snapshot
    # that is in storage *now*, which for a failure is the one that was there
    # before the run. That is deliberate and it is the reason this object
    # carries an age at all: a source that has failed to refresh for nine days
    # is still answering screening calls, and the only thing standing between
    # that and an undetected compliance gap is that the age is visible. An
    # alert on `result.failed?` fires once; an alert on `result.age` is what
    # notices a source that has been quietly failing since Tuesday.
    #
    # `stored?` is the loud case underneath it: a source that failed with
    # nothing stored behind it is not stale, it is absent, and screening will
    # not cover that list at all.
    #
    # ### Serializable, on purpose
    #
    # A host application alerts on a degrading source, and it should not have
    # to parse a log line to do it. `#to_h` is JSON-ready and `.from_h` rebuilds
    # it; the one thing that does not survive the round-trip is the exception
    # object, since a backtrace is not something to put in a metrics pipeline.
    # `error_class` and `error_message` do survive, because those are what an
    # alert is written against.
    #
    # Instances are frozen on construction and compare by value.
    class Result
      extend T::Sig

      STATUSES = T.let(%i[updated unchanged failed].freeze, T::Array[Symbol])

      MEMBERS = T.let(
        %i[source status record_count checksum fetched_at age duration error].freeze,
        T::Array[Symbol]
      )

      sig { returns(Symbol) }
      attr_reader :source

      # One of STATUSES.
      sig { returns(Symbol) }
      attr_reader :status

      # Records stored for this source now -- not records fetched. A failed
      # source reports what its retained snapshot holds, and nil only when
      # there is no snapshot at all.
      sig { returns(T.nilable(Integer)) }
      attr_reader :record_count

      # The checksum of the snapshot in storage now, which is what a match
      # result cites. Unchanged between two runs means the same list answered
      # both.
      sig { returns(T.nilable(String)) }
      attr_reader :checksum

      # When the snapshot in storage now was fetched -- for a failure, before
      # this run.
      sig { returns(T.nilable(Time)) }
      attr_reader :fetched_at

      # Seconds between `fetched_at` and the end of this source's sync, fixed
      # here rather than computed on demand so that a serialized report says
      # how stale the data was when the run saw it and not how long the report
      # has since sat in a queue.
      sig { returns(T.nilable(Integer)) }
      attr_reader :age

      # Wall-clock seconds this source took, fetch through store.
      sig { returns(Float) }
      attr_reader :duration

      # The exception that was captured, for a caller that wants the backtrace.
      # nil after a round-trip through #to_h -- see the class comment.
      sig { returns(T.nilable(Exception)) }
      attr_reader :exception

      # Rebuilds from #to_h output, accepting string keys so a report survives
      # the trip through JSON.
      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Sync::Result attribute(s): #{unknown.join(", ")}" if unknown.any?

        # `new(**hash)` past required keyword parameters is one of the few
        # things Sorbet cannot check statically; #initialize validates what
        # arrives.
        T.unsafe(self).new(**attributes)
      end

      # `error` takes the exception itself -- which is what the orchestrator
      # captured -- or the `{class:, message:}` pair #to_h wrote.
      sig do
        params(source: T.untyped, status: T.untyped, duration: T.untyped, record_count: T.untyped,
               checksum: T.untyped, fetched_at: T.untyped, age: T.untyped, error: T.untyped).void
      end
      def initialize(source:, status:, duration: 0.0, record_count: nil, checksum: nil, fetched_at: nil,
                     age: nil, error: nil)
        @source = T.let(symbol!(:source, source), Symbol)
        @status = T.let(status!(status), Symbol)
        @duration = T.let(duration.to_f, Float)
        @record_count = T.let(count!(record_count), T.nilable(Integer))
        @checksum = T.let(string_or_nil(checksum), T.nilable(String))
        @fetched_at = T.let(time_or_nil(fetched_at), T.nilable(Time))
        @age = T.let(integer_or_nil(age), T.nilable(Integer))
        @exception = T.let(error.is_a?(Exception) ? error : nil, T.nilable(Exception))
        @failure = T.let(failure!(error), T.nilable(T::Hash[Symbol, String]))
        freeze
      end

      # The exception's class name, and its message. Strings rather than the
      # class itself: this is what survives into a metrics pipeline, and a
      # constant that no longer exists in the process reading a year-old report
      # is not something to make it resolve.
      sig { returns(T.nilable(String)) }
      def error_class = @failure&.fetch(:class)

      sig { returns(T.nilable(String)) }
      def error_message = @failure&.fetch(:message)

      sig { returns(T::Boolean) }
      def updated? = status == :updated

      sig { returns(T::Boolean) }
      def unchanged? = status == :unchanged

      sig { returns(T::Boolean) }
      def failed? = status == :failed

      # Whether there is a snapshot to screen this source against. False is the
      # state that matters more than a failure: a list nothing is stored for is
      # not covered by a screening run at all.
      sig { returns(T::Boolean) }
      def stored? = !checksum.nil?

      # A failure that kept its previous good snapshot -- the behaviour this
      # whole run is arranged around.
      sig { returns(T::Boolean) }
      def retained? = failed? && stored?

      # The failure on one line, for a log or a table. nil when nothing failed.
      sig { returns(T.nilable(String)) }
      def error
        return nil unless error_class

        message = error_message
        # `raise SomeError` with no message gives a message that is the class
        # name, and "SomeError: SomeError" is not a line worth logging.
        return error_class if message.nil? || message.empty? || message == error_class

        "#{error_class}: #{message}"
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          source: source,
          status: status,
          record_count: record_count,
          checksum: checksum,
          fetched_at: fetched_at&.iso8601,
          age: age,
          duration: duration,
          error: @failure
        }
      end

      # "3h old" rather than "10800 seconds": this is read by a human in a
      # summary table, and the question being asked of it is only ever "is that
      # a long time?". A source with nothing stored says so instead, because
      # the age of a list that is not there is not the problem with it.
      sig { returns(String) }
      def age_in_words
        return "nothing stored" unless stored?

        seconds = age
        return "unknown age" if seconds.nil?

        [[86_400, "d"], [3_600, "h"], [60, "m"]].each do |(unit, suffix)|
          return "#{seconds / unit}#{suffix} old" if seconds >= unit
        end
        "just fetched"
      end

      sig { returns(String) }
      def to_s
        detail = failed? ? error.to_s : "#{record_count || 0} records, #{age_in_words}"
        "#{source} #{status} in #{format("%.2f", duration)}s: #{detail}"
      end

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{self}>"

      private

      sig { params(value: T.untyped).returns(Symbol) }
      def status!(value)
        status = symbol!(:status, value)
        return status if STATUSES.include?(status)

        raise InvalidArgument, "status must be one of #{STATUSES.join(", ")}, got #{value.inspect}"
      end

      # Takes the exception the orchestrator captured, or the pair #to_h wrote
      # -- with string keys, since a report that has been through JSON has
      # string keys all the way down.
      sig { params(value: T.untyped).returns(T.nilable(T::Hash[Symbol, String])) }
      def failure!(value)
        case value
        when nil then nil
        when Exception then { class: value.class.name.to_s, message: value.message.to_s }.freeze
        else
          pair = value.to_h.transform_keys(&:to_sym)
          name = string_or_nil(pair[:class])
          name && { class: name, message: pair[:message].to_s }.freeze
        end
      end

      sig { params(value: T.untyped).returns(T.nilable(Integer)) }
      def count!(value)
        integer = integer_or_nil(value)
        raise InvalidArgument, "record_count cannot be negative, got #{integer}" if integer&.negative?

        integer
      end

      # An age may be negative where a publisher's clock is ahead of ours, so
      # unlike a record count it is not checked for it.
      sig { params(value: T.untyped).returns(T.nilable(Integer)) }
      def integer_or_nil(value) = value.nil? ? nil : Integer(value)

      sig { params(value: T.untyped).returns(T.nilable(Time)) }
      def time_or_nil(value)
        case value
        when nil then nil
        when Time then Time.at(value.to_i).utc
        when String then Time.at(Time.parse(value).to_i).utc
        else raise InvalidArgument, "fetched_at is not a time: #{value.inspect}"
        end
      end

      sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
      def symbol!(member, value)
        raise InvalidArgument, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end

      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def string_or_nil(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : -string
      end
    end
  end
end
