# typed: strict
# frozen_string_literal: true

module ActiveSanction
  # Base class for every error this library raises, so an application can
  # rescue the whole gem without naming each failure it knows about.
  class Error < StandardError; end
end
