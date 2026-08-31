# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Sources
    class Ofac < Base
      class RemarksParser
        # What OFAC calls things: every label the parser knows how to find at
        # the front of a remark segment, and the patterns compiled from them.
        #
        # Kept apart from the parsing because they change for different
        # reasons. How a segment is read is settled; which words OFAC opens one
        # with is not, and is what a maintainer edits when Coverage#top shows a
        # spelling nobody has seen before. The tail of that list is long and
        # thin -- a dozen country-specific labels appear fewer than 30 times
        # each -- so this table is deliberately the high-volume ones rather
        # than an attempt at all of them.
        module Vocabulary
          extend T::Sig

          # The labels that map onto a canonical field. `citizen` and
          # `nationality` are one field written two ways, and OFAC uses both.
          FIELDS = T.let({
            "DOB" => :date_of_birth,
            "POB" => :place_of_birth,
            "nationality" => :nationality,
            "citizen" => :nationality,
            "Gender" => :gender,
            "a.k.a." => :aka,
            "f.k.a." => :fka,
            "n.k.a." => :nka
          }.freeze, T::Hash[String, Symbol])

          # Every document label OFAC writes, grouped by the Identifier kind it
          # means. One kind covers many labels because governments name the
          # same document differently -- an R.F.C. is Mexico's tax number and a
          # NIT is Colombia's -- and a matcher comparing numbers should not
          # have to know whose vocabulary it is holding. The published label is
          # not lost: it becomes the identifier's `note`, because :tax_id is
          # our word for it and "R.F.C." is theirs, and a user justifying a hit
          # needs to see theirs.
          DOCUMENTS = T.let({
            passport: ["Passport", "Diplomatic Passport"],
            national_id: [
              "National ID No.", "Identification Number", "Cedula No.", "C.U.R.P.", "C.U.I.P.",
              "D.N.I.", "C.I.N.", "Driver's License No.", "Birth Certificate Number", "Residency Number"
            ],
            tax_id: [
              "Tax ID No.", "R.F.C.", "V.A.T. Number", "NIT", "RUC", "RIF",
              "Unified Social Credit Code (USCC)"
            ],
            registration_number: [
              "Registration Number", "Business Registration Number", "Business Registration Document",
              "Company Number", "Commercial Registry Number", "Registration ID", "Government Gazette Number",
              "Folio Mercantil No.", "Matricula Mercantil No", "Legal Entity Number", "Chamber of Commerce Number",
              "Trade License No.", "License", "C.R. No.", "Economic Register Number (CBLS)",
              "Central Registration System Number", "D-U-N-S Number", "Enterprise Number", "Business Number",
              "Entity Code", "Public Registration Number"
            ],
            # Registered strings that are not documents: a vessel's IMO number,
            # a bank's SWIFT code, an aircraft's serial. :other is a real
            # answer -- a number we cannot classify still matches on its number.
            other: [
              "MMSI", "Vessel Registration Identification IMO", "Vessel Registration Identification",
              "Identification Number IMO", "Company Number IMO", "SWIFT/BIC",
              "Aircraft Manufacturer's Serial Number (MSN)", "Aircraft Tail Number",
              # Published with its own gloss attached, every time, all 52 of them.
              "Aircraft Construction Number (also called L/N or S/N or F/N)", "Aircraft Construction Number"
            ]
          }.freeze, T::Hash[Symbol, T::Array[String]])

          # Shapes that are recognized and carry nothing to extract: statutory
          # citations, relationship notes, contact details, the date a company
          # rather than a person was established. Naming them is what makes the
          # coverage statistic mean something -- without this list the number
          # would sit near half forever and real drift would hide in the noise.
          PROSE = T.let([
            "Secondary sanctions risk", "Additional Sanctions Information", "Linked To",
            "Transactions Prohibited For Persons Owned or Controlled By U.S. Financial Institutions",
            "Organization Established Date", "Organization Type", "Target Type", "Executive Order",
            "CAATSA Section", "For more information", "Website", "Email Address", "Phone Number",
            "Telephone", "Fax", "Vessel Year of Build", "Former Vessel Flag", "Aircraft Manufacture Date",
            "Aircraft Model", "Aircraft Operator"
          ].freeze, T::Array[String])

          # A label is followed by whitespace, a `#` (`NIT # 123`) or a colon,
          # and may carry one full stop this table does not spell ("Matricula
          # Mercantil No." against "Matricula Mercantil No"). The lookahead is
          # what stops "Passport" from matching the first word of a longer
          # label, and the longest-first ordering is what stops "Business
          # Registration Number" from being read as a stray word and then
          # "Registration Number".
          #
          # The alternation is escaped and joined by hand rather than built
          # with Regexp.union, which embeds its own `(?-mix:...)` and would
          # switch case-insensitivity back off for the labels inside it.
          sig { params(labels: T::Array[String], tail: String).returns(Regexp) }
          def self.pattern(labels, tail)
            alternation = labels.sort_by { |label| -label.length }.map { |label| Regexp.escape(label) }.join("|")
            /\A(?<label>#{alternation})\.?(?=[\s#:]|\z)[\s#:]*#{tail}\z/i
          end

          DOCUMENT_KINDS = T.let(
            DOCUMENTS.each_with_object({}) do |(kind, labels), lookup|
              labels.each { |label| lookup[label.downcase] = kind }
            end.freeze,
            T::Hash[String, Symbol]
          )

          FIELD_KINDS = T.let(FIELDS.transform_keys(&:downcase).freeze, T::Hash[String, Symbol])

          FIELD_PATTERN = T.let(pattern(FIELDS.keys, "(?<value>.*)"), Regexp)
          DOCUMENT_PATTERN = T.let(pattern(DOCUMENTS.values.flatten, "(?<rest>.*)"), Regexp)
          PROSE_PATTERN = T.let(pattern(PROSE, ".*"), Regexp)
        end
      end
    end
  end
end
