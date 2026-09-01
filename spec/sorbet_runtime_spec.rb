# frozen_string_literal: true

require "open3"

# Not a spec for a class: this is the promise #73 makes to a host application,
# which is that taking on `sorbet-runtime` changed nothing it can observe.
#
# The static half of that promise is `srb tc`, which CI runs. This is the half
# a checker cannot make -- what the signatures do at runtime, in a process that
# never asked for them.
RSpec.describe "Sorbet's runtime" do
  # What a signature is worth at runtime, which is less than what it is worth
  # to `srb tc` and is worth stating in a test rather than in a comment: the
  # check is shallow. A member of the wrong shape is refused; an Array holding
  # the wrong thing is not, which is why the adapter conformance group still
  # asserts per fixture that a date arrives as a PartialDate.
  describe "the guarantee it adds" do
    it "refuses a canonical member of the wrong shape" do
      expect { ActiveSanction::Entity.new(source: :ofac_sdn, source_ref: "1", type: :individual, names: "AL Z") }
        .to raise_error(TypeError, /Expected type T.nilable\(T::Array\[ActiveSanction::Name\]\)/)
    end

    it "does not look inside a collection, which is the checker's job" do
      built = ActiveSanction::Entity.new(source: :ofac_sdn, source_ref: "1", type: :individual,
                                         dates_of_birth: ["1972"])

      expect(built.dates_of_birth).to eq(["1972"])
    end
  end

  # Run in a subprocess because a signature is compiled once, on the first call
  # to the method it describes: setting the level after this suite has already
  # exercised the library would prove nothing about a host that sets it at
  # boot, which is where the documented line goes.
  describe "T::Configuration.default_checked_level = :never" do
    it "leaves the library's own behaviour intact" do
      expect(run(<<~RUBY)).to eq("ok\n")
        entity = ActiveSanction::Entity.new(source: :ofac_sdn, source_ref: "2674", type: :individual,
                                            names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman")])
        raise "id" unless entity.id == "ofac_sdn:2674"
        raise "round trip" unless ActiveSanction::Entity.from_h(entity.to_h) == entity

        puts "ok"
      RUBY
    end

    # The signature stops speaking and the value object's own validation is
    # what answers -- which is the arrangement #73 is built around: the
    # messages here are written for whoever has to fix the record, and a type
    # error says less than they do.
    it "leaves the library's own validation to say what is wrong" do
      expect(run(<<~RUBY)).to eq("names must be an Array\n")
        begin
          ActiveSanction::Entity.new(source: :ofac_sdn, source_ref: "1", type: :individual, names: "AL Z")
        rescue ArgumentError => e
          puts e.message
        end
      RUBY
    end
  end

  # The other half of the rule the gemspec states: a signature on a path that
  # runs per query is declared `.checked(:tests)`, so this suite enforces it --
  # spec_helper turns those checks on -- and a host's process never pays for
  # it. The normalizer is the first such path; the scorers (#32) join it.
  describe "a per-query signature" do
    it "is enforced here, which is what `:tests` means" do
      expect { ActiveSanction::Normalizer::DEFAULT.cache.fetch(:ofac_sdn) { raise "not reached" } }
        .to raise_error(TypeError, /Expected type String/)
    end

    it "is inert in a host that configured nothing at all" do
      expect(run(<<~RUBY, configure: "")).to eq("belarus\n")
        cache = ActiveSanction::Normalizer::DEFAULT.cache
        puts cache.fetch(:a_key_of_the_wrong_type) { ActiveSanction::Normalizer::Form.new("Bélarus") }.value
      RUBY
    end
  end

  # `-` is stdin, so the program never touches the filesystem; `lib` is on the
  # load path rather than the gem being installed, which is what makes this run
  # against the checkout.
  #
  # `configure:` is what the host does before requiring the gem. Empty is the
  # ordinary host: every default left alone, nothing turned off.
  def run(program, configure: "T::Configuration.default_checked_level = :never")
    preamble = <<~RUBY
      require "sorbet-runtime"
      #{configure}
      require "active_sanction"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-",
                                     stdin_data: "#{preamble}#{program}")
    raise "the subprocess failed: #{output}" unless status.success?

    output
  end
end
