# frozen_string_literal: true

RSpec.describe ActiveSanction::Rescreen do
  after { ActiveSanction.reset! }

  def entity(ref, names, **overrides)
    ActiveSanction::Entity.new(
      source: :ofac_sdn, source_ref: ref.to_s, type: :individual,
      names: Array(names).each_with_index.map do |value, position|
        ActiveSanction::Name.new(value: value, kind: position.zero? ? :primary : :aka)
      end,
      programs: ["SDGT"], **overrides
    )
  end

  def snapshot(entities) = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: entities)

  def diff(from, to) = ActiveSanction::Diff.new(from: from, to: to)

  def customer(id, name, **overrides) = ActiveSanction::Subject.new(id: id, name: name, **overrides)

  # One record nobody in these books looks like, so that no snapshot is empty
  # and no diff reports a list that emptied itself.
  def unrelated = entity(36, "AEROCARIBBEAN AIRLINES", type: :organization)
  def ntaganda = entity(41_234, "NTAGANDA, Bosco")
  def abbas = entity(2674, "ABBAS, Abu")

  def book = [customer("cust_1", "Bosco Ntaganda"), customer("cust_2", "Jane Miller")]

  # One record listed today that was not listed yesterday.
  def listing = diff(snapshot([unrelated]), snapshot([unrelated, ntaganda]))

  def alerts(subjects = book, changes = listing, threshold: 75)
    described_class.call(subjects, diff: changes, threshold: threshold)
  end

  describe "a record the new list has and the old did not" do
    # The acceptance criterion: exactly one alert, and it names the customer.
    it "raises one newly listed alert for the subject that matches it" do
      expect(alerts.map { |alert| [alert.subject_id, alert.change] }).to eq([["cust_1", :newly_listed]])
    end

    it "carries the full match result, with its explanation" do
      expect(alerts.first.result).to have_attributes(score: (a_value >= 75), explanation: be_any)
    end

    # There was no such record to score against, so there is no prior score --
    # which is a different answer from a prior score of zero.
    it "has no previous side" do
      expect(alerts.first).to have_attributes(previous_result: nil, previous_score: nil)
    end

    it "raises nothing for a subject that matches nothing that moved" do
      expect(alerts([customer("cust_2", "Jane Miller")])).to be_empty
    end
  end

  describe "a record the old list had and the new does not" do
    def delisting = diff(snapshot([unrelated, abbas]), snapshot([unrelated]))

    # A delisting is what lets a customer back through the door, and a service
    # that never notices one goes on blocking somebody.
    it "raises a delisted alert for the subject whose only matching record went away" do
      expect(alerts([customer("cust_3", "Abu Abbas")], delisting).map(&:change)).to eq([:delisted])
    end

    it "has no current side, because the record is no longer on the list" do
      expect(alerts([customer("cust_3", "Abu Abbas")], delisting).first)
        .to have_attributes(result: nil, score: nil, previous_score: a_value >= 75)
    end

    it "scores the previous side against the list version that still had it" do
      expect(alerts([customer("cust_3", "Abu Abbas")], delisting).first.previous_result.snapshot_id)
        .to eq(delisting.from.checksum)
    end
  end

  describe "a record that was amended" do
    def before_amendment = snapshot([unrelated, entity(2674, "ZAYDAN, Muhammad")])
    def after_amendment = snapshot([unrelated, entity(2674, ["ZAYDAN, Muhammad", "Abu Abbas"])])
    def amendment = diff(before_amendment, after_amendment)

    it "reports a subject that matched before and still matches as details changed" do
      expect(alerts([customer("cust_4", "Muhammad Zaydan")], amendment).map(&:change)).to eq([:details_changed])
    end

    # The amendment is what brought the subject over the line, which is the
    # same event for a compliance team as a new listing.
    it "reports a subject the amendment brought over the line as newly listed" do
      expect(alerts([customer("cust_5", "Abu Abbas")], amendment).map(&:change)).to eq([:newly_listed])
    end

    # "moved from 71 to 94", not merely "now matches".
    it "carries the prior score, below the threshold though it was" do
      expect(alerts([customer("cust_5", "Abu Abbas")], amendment).first)
        .to have_attributes(previous_score: a_value < 75, score: a_value >= 75)
    end

    it "reports a subject the amendment moved out of range as delisted" do
      expect(alerts([customer("cust_5", "Abu Abbas")], diff(after_amendment, before_amendment)).first)
        .to have_attributes(change: :delisted, previous_score: a_value >= 75, score: a_value < 75)
    end

    it "says which fields moved" do
      expect(alerts([customer("cust_4", "Muhammad Zaydan")], amendment).first.fields).to eq(%i[names])
    end

    # A program added or an address corrected changes what a hit means without
    # changing what it scores, and a library that filtered those would be
    # deciding which sanctions hits a host is willing to miss.
    it "raises an alert for an amendment that does not move the score at all" do
      amended = snapshot([unrelated, entity(2674, "ZAYDAN, Muhammad", programs: %w[SDGT SDNTK])])
      raised = alerts([customer("cust_4", "Muhammad Zaydan")], diff(before_amendment, amended)).first

      expect(raised).to have_attributes(change: :details_changed, fields: %i[programs],
                                        score: raised.previous_score)
    end
  end

  describe "an empty diff" do
    it "yields no alerts, and does not so much as read the book" do
      unchanged = diff(snapshot([unrelated, ntaganda]), snapshot([unrelated, ntaganda]))
      refuses = Class.new { def each(*) = raise("a rescreen against an empty diff scored something") }.new

      expect(alerts(refuses, unchanged)).to eq([])
    end

    # A first sync is a baseline rather than 19,015 new listings, so it raises
    # nothing: the right response to one is a deliberate full screening run.
    it "yields nothing for a baseline" do
      expect(alerts(book, ActiveSanction::Diff.new(to: snapshot([unrelated, ntaganda])))).to eq([])
    end
  end

  describe "the audit stamp" do
    it "cites both list versions, so the run can be derived again" do
      expect(alerts.first).to have_attributes(snapshot_id: listing.to.checksum,
                                              previous_snapshot_id: listing.from.checksum)
    end

    it "stamps each result with the checksum of the list version it was scored against" do
      expect(alerts.first.result.snapshot_id).to eq(listing.to.checksum)
    end

    it "records the question that was asked, at the threshold it was asked under" do
      expect(alerts.first.result.query)
        .to have_attributes(name: "Bosco Ntaganda", threshold: 75.0, sources: %i[ofac_sdn])
    end

    # A rescreening of a book is one event in an audit trail, not ten thousand
    # of them a microsecond apart.
    it "stamps one screened_at across a whole run" do
      raised = alerts([customer("cust_1", "Bosco Ntaganda"), customer("cust_6", "Bosco Ntaganda")])

      expect(raised.map(&:screened_at).uniq.size).to eq(1)
    end
  end

  describe "thresholds" do
    it "takes the run's threshold" do
      expect(alerts(book, listing, threshold: 99)).to be_empty
    end

    # Risk-based screening: a correspondent bank at 70 beside a retail
    # customer at 85, in one book and one run.
    it "lets a subject name its own" do
      expect(alerts([customer("vip", "Bosco Ntaganda", threshold: 99)], listing, threshold: 50)).to be_empty
    end

    it "defaults to the configured screening threshold" do
      ActiveSanction.configure { |config| config.screening_threshold = 99 }

      expect(described_class.new(diff: listing).threshold).to eq(99.0)
    end
  end

  describe "streaming a book" do
    it "calls the block with each alert as it is raised" do
      raised = []
      described_class.call(book, diff: listing, threshold: 75) { |alert| raised << alert.subject_id }

      expect(raised).to eq(%w[cust_1])
    end

    it "takes anything enumerable, so a database cursor is not materialized" do
      expect(alerts(book.each).map(&:subject_id)).to eq(%w[cust_1])
    end

    it "takes the Hashes a host already has, without mapping them first" do
      expect(alerts([{ id: "cust_1", name: "Bosco Ntaganda" }]).map(&:subject_id)).to eq(%w[cust_1])
    end

    it "refuses a book that is not enumerable" do
      expect { alerts(customer("cust_1", "Bosco Ntaganda")) }
        .to raise_error(ActiveSanction::InvalidArgument, /has to be enumerable/)
    end

    # One index, built once, so a host streaming a large book in batches does
    # not pay for it per batch.
    it "is reusable across batches" do
      rescreening = described_class.new(diff: listing, threshold: 75)

      expect(book.each_slice(1).flat_map { |slice| rescreening.call(slice) }.map(&:subject_id)).to eq(%w[cust_1])
    end
  end

  describe "determinism" do
    # Two runs over the same diff and the same book have to produce the same
    # alerts in the same order, or an alert is not re-derivable.
    it "orders a subject's alerts by score, and then by record id" do
      twin = entity(41_235, "NTAGENDA, Bosco")
      raised = alerts([customer("cust_1", "Bosco Ntaganda")],
                      diff(snapshot([unrelated]), snapshot([unrelated, ntaganda, twin])))

      expect(raised.map(&:score)).to eq(raised.map(&:score).sort.reverse)
    end

    it "produces equal alerts on two runs over the same diff" do
      rescreening = described_class.new(diff: listing, threshold: 75)
      first = rescreening.call(book).map(&:to_h)

      expect(rescreening.call(book).map(&:to_h)).to eq(first)
    end
  end

  describe "what it refuses" do
    it "refuses anything that is not a Diff" do
      expect { described_class.new(diff: :ofac_sdn) }
        .to raise_error(ActiveSanction::InvalidArgument, /must be an ActiveSanction::Diff/)
    end
  end

  describe "readers" do
    it "reports the list and how much of it moved" do
      expect(described_class.new(diff: listing)).to have_attributes(source: :ofac_sdn, size: 1, empty?: false)
    end

    it "is frozen, so a book streams past one from as many threads as a host has" do
      expect(described_class.new(diff: listing)).to be_frozen
    end

    it "inspects as the run it is" do
      expect(described_class.new(diff: listing, threshold: 75).inspect)
        .to eq("#<ActiveSanction::Rescreen ofac_sdn 1 changed records at 75.0>")
    end
  end
end
