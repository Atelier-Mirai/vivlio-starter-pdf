# frozen_string_literal: true

require "hexapdf"

module VivlioStarter
  module Pdf
    # Internal helper responsible for translating outline entries into HexaPDF structures.
    class OutlineWriter
      # @param doc [HexaPDF::Document] target document
      # @param max_level [Integer] maximum depth allowed in the outline tree
      # @param on_skip [Proc,nil] callback triggered when an entry is ignored
      def initialize(doc, max_level:, on_skip: nil)
        @doc = doc
        @max_level = max_level.to_i.clamp(1, 6)
        @page_count = @doc.pages.count
        @on_skip = on_skip
      end

      # Writes the given +items+ into the document outline.
      # @param items [Array<Hash>] entries with :level, :text, :page
      # @return [Integer] number of inserted outline nodes
      def write(items)
        return 0 if @page_count.zero?

        normalized = Array(items).filter_map { normalize_entry(it) }
        return 0 if normalized.empty?

        outline_root = rebuild_outline_root
        stack = [{ level: 0, node: outline_root }]
        inserted = 0

        normalized.each do |entry|
          parent = parent_for(entry[:level], stack)
          destination = resolve_destination(entry[:page])
          unless destination
            warn_skip("page #{entry[:page]} is outside 1-#{@page_count}")
            next
          end

          item = parent.add_item(entry[:text], destination:, open: entry[:level] < @max_level)
          stack << { level: entry[:level], node: item }
          inserted += 1
        end

        if inserted.zero?
          @doc.catalog.delete(:Outlines)
          return 0
        end

        inserted
      end

      private

      # Normalizes a raw hash into a consistent entry structure.
      def normalize_entry(raw)
        text = fetch(raw, :text, fetch(raw, :title, nil)).to_s.strip
        warn_skip("missing title for outline entry: #{raw.inspect}") if text.empty?
        return nil if text.empty?

        page = fetch(raw, :page, nil).to_i
        if page <= 0
          warn_skip("invalid page for outline entry: #{raw.inspect}")
          return nil
        end

        level = fetch(raw, :level, 1).to_i
        level = 1 if level < 1
        level = @max_level if level > @max_level

        { text:, page:, level: }
      end

      # Fetches a value from the entry by symbol or string key.
      def fetch(raw, key, fallback)
        if raw.respond_to?(:[]) && (raw[key] || raw[key.to_s])
          raw[key] || raw[key.to_s]
        else
          fallback
        end
      end

      # Returns the proper parent node for the requested level.
      def parent_for(level, stack)
        while stack.last[:level] >= level
          break if stack.size == 1
          stack.pop
        end
        stack.last[:node]
      end

      # Resolves the destination page for an entry.
      def resolve_destination(page_number)
        index = page_number.to_i - 1
        return nil unless index.between?(0, @page_count - 1)

        @doc.pages[index]
      rescue StandardError
        nil
      end

      # Recreates an empty outline root before inserting new nodes.
      def rebuild_outline_root
        @doc.catalog.delete(:Outlines)
        outline_root = @doc.add({ Type: :Outlines }, type: :Outlines)
        @doc.catalog[:Outlines] = outline_root
        outline_root
      end

      # Emits skip notifications through the provided callback.
      def warn_skip(message)
        @on_skip&.call(message)
      end
    end
  end
end
