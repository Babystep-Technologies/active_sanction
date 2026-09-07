# frozen_string_literal: true

require "zlib"

# Builds .xlsx payloads in memory, so the spreadsheet toolkit can be held to
# the shapes a published workbook does not happen to contain today.
#
#   WorkbookBuilder.build(rows: [%w[Name Born], ["ADAM", "1975"]])
#   WorkbookBuilder.new.part("xl/styles.xml", "not xml").zip
#
# The Australian fixture is the real evidence and every mapping question is
# answered against it. This is for the container and the cell -- a ZIP64 header,
# an encrypted entry, a 1904 date system, an inline string -- none of which DFAT
# publishes and all of which a reader that claims to read `.xlsx` will meet.
class WorkbookBuilder
  CONTENT_TYPES = <<~XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="xml" ContentType="application/xml"/>
    </Types>
  XML

  RELS = <<~XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
  XML

  WORKBOOK_RELS = <<~XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
  XML

  # Style 0 is General, 1 is `m/d/yyyy` (builtin 14), 2 is `mmm-yy` (builtin 17,
  # a month), 3 is `h:mm` (builtin 20, a time and not a date), and 4 is a custom
  # `yyyy` -- a year and nothing else.
  STYLES = <<~XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <numFmts count="1"><numFmt numFmtId="180" formatCode="yyyy"/></numFmts>
    <cellStyleXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellStyleXfs>
    <cellXfs count="5">
    <xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="17"/><xf numFmtId="20"/><xf numFmtId="180"/>
    </cellXfs>
    </styleSheet>
  XML

  # The whole point of a fluent builder here: an example says what it is about
  # by replacing one part, and inherits a workbook that reads correctly for
  # everything else.
  def self.build(...) = new(...).zip

  # The same, starting from a real published workbook: read its parts out,
  # change one, write it back. What an example uses to ask what an adapter does
  # when the publisher changes the file it has always sent.
  def self.from(bytes)
    archive = ActiveSanction::Parsers::Spreadsheet::Archive.new(bytes)
    new.tap do |builder|
      builder.parts.clear
      archive.names.each { |name| builder.parts[name] = archive.fetch(name) }
    end
  end

  attr_reader :parts

  # `rows` is an array of arrays of cell values. A String becomes a shared
  # string, an Integer or Float a number, nil an empty cell, and a two-element
  # [value, style] pair a cell carrying that style index.
  def initialize(rows: [%w[Reference Name], %w[1 ADAM]], sheet: "Sheet1", date1904: false)
    @strings = []
    @parts = {
      "[Content_Types].xml" => CONTENT_TYPES,
      "_rels/.rels" => RELS,
      "xl/workbook.xml" => workbook(sheet, date1904),
      "xl/_rels/workbook.xml.rels" => WORKBOOK_RELS,
      "xl/styles.xml" => STYLES,
      "xl/worksheets/sheet1.xml" => sheet_xml(rows),
      "xl/sharedStrings.xml" => shared_strings,
      "docProps/core.xml" => core
    }
  end

  # A cell written out as literal XML, for the shapes the builder has no
  # shorthand for: an inline string, a boolean, a formula's cached result.
  RawCell = Struct.new(:attributes, :body)

  def self.raw(attributes, body) = RawCell.new(attributes, body)

  # Replaces or adds a part. `nil` removes one.
  def part(name, body)
    body.nil? ? @parts.delete(name) : @parts[name] = body
    self
  end

  def zip(flags: 0, method: 8, corrupt: nil)
    local = +"".b
    central = +"".b
    offsets = {}
    parts.each do |name, body|
      offsets[name] = local.bytesize
      entry(local, central, name, body.to_s.b, flags: flags, method: method, offset: offsets[name])
    end
    local[offsets.fetch(corrupt), 4] = "PK\x03\x05".b if corrupt
    local + central + ["PK\x05\x06".b, 0, 0, parts.size, parts.size,
                       central.bytesize, local.bytesize, 0].pack("a4vvvvVVv")
  end

  private

  def entry(local, central, name, bytes, flags:, method:, offset:)
    data = method.zero? ? bytes : deflate(bytes)
    sizes = [Zlib.crc32(bytes), data.bytesize, bytes.bytesize]
    local << ["PK\x03\x04".b, 20, flags, method, 0, 0, *sizes, name.bytesize, 0].pack("a4vvvvvVVVvv")
    local << name.b << data
    central << ["PK\x01\x02".b, 20, 20, flags, method, 0, 0, *sizes,
                name.bytesize, 0, 0, 0, 0, 0, offset].pack("a4vvvvvvVVVvvvvvVV") << name.b
  end

  def deflate(bytes)
    stream = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
    (stream.deflate(bytes) << stream.finish).tap { stream.close }
  end

  def workbook(sheet, date1904)
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <workbookPr#{' date1904="1"' if date1904}/>
      <sheets><sheet name="#{sheet}" sheetId="1" r:id="rId1"/></sheets>
      </workbook>
    XML
  end

  def core
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                         xmlns:dcterms="http://purl.org/dc/terms/">
      <dcterms:created>2026-01-01T00:00:00Z</dcterms:created>
      <dcterms:modified>2026-09-04T05:37:12Z</dcterms:modified>
      </cp:coreProperties>
    XML
  end

  def sheet_xml(rows)
    body = rows.each_with_index.map { |cells, index| row_xml(cells, index + 1) }.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>#{body}</sheetData>
      </worksheet>
    XML
  end

  def row_xml(cells, number)
    body = cells.each_with_index.map { |cell, index| cell_xml(cell, column(index), number) }.join
    %(<row r="#{number}">#{body}</row>)
  end

  # `A`, `B`, ... `Z`, `AA`: enough for any sheet a spec builds.
  def column(index)
    index < 26 ? (65 + index).chr : "#{(64 + (index / 26)).chr}#{(65 + (index % 26)).chr}"
  end

  def cell_xml(cell, letter, number)
    value, style = cell.is_a?(Array) ? cell : [cell, nil]
    attributes = %( r="#{letter}#{number}") + (style ? %( s="#{style}") : "")
    return %(<c#{attributes}/>) if value.nil?
    return %(<c#{attributes}><v>#{value}</v></c>) if value.is_a?(Numeric)
    return %(<c#{attributes}#{value.attributes}>#{value.body}</c>) if value.is_a?(RawCell)

    %(<c#{attributes} t="s"><v>#{intern(value)}</v></c>)
  end

  def intern(value)
    @strings.index(value) || ((@strings << value).size - 1)
  end

  def shared_strings
    entries = @strings.map { |value| "<si><t>#{escape(value)}</t></si>" }.join
    %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) +
      %(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ) +
      %(count="#{@strings.size}" uniqueCount="#{@strings.size}">#{entries}</sst>)
  end

  def escape(value) = value.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end
