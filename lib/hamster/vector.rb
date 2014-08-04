require "forwardable"
require "hamster/immutable"
require "hamster/enumerable"

module Hamster
  def self.vector(*items)
    items.empty? ? EmptyVector : Vector.new(items.freeze)
  end

  class Vector
    extend Forwardable
    include Immutable
    include Enumerable

    BLOCK_SIZE = 32
    INDEX_MASK = BLOCK_SIZE - 1
    BITS_PER_LEVEL = 5

    attr_reader :size
    def_delegator :self, :size, :length

    class << self
      def [](*items)
        new(items.freeze)
      end

      def empty
        @empty ||= self.alloc([].freeze, 0, 0)
      end

      def alloc(root, size, levels)
        obj = allocate
        obj.instance_variable_set(:@root, root)
        obj.instance_variable_set(:@size, size)
        obj.instance_variable_set(:@levels, levels)
        obj
      end
    end

    def initialize(items=[].freeze)
      items = items.to_a
      if items.size <= 32
        items = items.dup.freeze if !items.frozen?
        @root, @size, @levels = items, items.size, 0
      else
        root, size, levels = items, items.size, 0
        while root.size > 32
          root = root.each_slice(32).to_a
          levels += 1
        end
        @root, @size, @levels = root.freeze, size, levels
      end
    end

    def empty?
      @size == 0
    end
    def_delegator :self, :empty?, :null?

    def first
      get(0)
    end
    def_delegator :self, :first, :head

    def last
      get(-1)
    end

    def add(item)
      update_root(@size, item)
    end
    def_delegator :self, :add, :<<
    def_delegator :self, :add, :cons
    def_delegator :self, :add, :conj
    def_delegator :self, :add, :conjoin

    def set(index, item = yield(get(index)))
      raise IndexError if empty? || index == @size
      raise IndexError if index.abs > @size
      return set(@size + index, item) if index < 0
      update_root(index, item)
    end

    def get(index)
      return nil if empty? || index == @size
      return nil if index.abs > @size
      return get(@size + index) if index < 0
      leaf_node_for(@root, @levels * BITS_PER_LEVEL, index)[index & INDEX_MASK]
    end
    def_delegator :self, :get, :[]
    def_delegator :self, :get, :at

    def fetch(index, default = (missing_default = true))
      index += @size if index < 0
      if index >= 0 && index < size
        get(index)
      elsif !missing_default
        default
      elsif block_given?
        yield
      else
        raise IndexError, "index #{index} outside of vector bounds"
      end
    end

    def each(&block)
      return to_enum unless block_given?
      traverse_depth_first(&block)
      self
    end

    def reverse_each(&block)
      return enum_for(:reverse_each) unless block_given?
      reverse_traverse_depth_first(&block)
      self
    end

    def each_index(&block)
      return enum_for(:each_index) unless block_given?
      0.upto(@size-1, &block)
      self
    end

    def filter
      return enum_for(:filter) unless block_given?
      reduce(self.class.empty) { |vector, item| yield(item) ? vector.add(item) : vector }
    end

    def map
      return enum_for(:map) if not block_given?
      return self if empty?
      self.class.new(super)
    end
    def_delegator :self, :map, :collect

    def sort
      self.class.new(super)
    end
    def sort_by
      self.class.new(super)
    end

    def clear
      self.class.empty
    end

    def reverse
      self.class.new((a = to_a).frozen? ? a.reverse : a.reverse!)
    end

    def sample
      get(rand(@size))
    end

    def assoc(obj)
      each { |array| return array if obj == array[0] }
      nil
    end

    def rassoc(obj)
      each { |array| return array if obj == array[1] }
      nil
    end

    def inspect
      result = "#{self.class}["
      each_with_index { |obj, i| result << ', ' if i > 0; result << obj.inspect }
      result << "]"
    end

    def pretty_print(pp)
      pp.group(1, "#{self.class}[", "]") do
        pp.seplist(self) { |obj| obj.pretty_print(pp) }
      end
    end

    def to_a
      if @levels == 0
        @root
      else
        flatten = lambda do |result, node, distance_from_leaf|
          if distance_from_leaf == 1
            node.each { |a| result.concat(a) }
          else
            node.each { |a| flatten[result, a, distance_from_leaf-1] }
          end
          result
        end
        flatten[[], @root, @levels]
      end
    end

    def eql?(other)
      return true if other.equal?(self)
      return false unless instance_of?(other.class) && @size == other.size
      @root.eql?(other.instance_variable_get(:@root))
    end

    def ==(other)
      self.eql?(other) || other.respond_to?(:to_ary) && to_ary.eql?(other.to_ary)
    end

    private

    def traverse_depth_first(node = @root, level = @levels, &block)
      return node.each(&block) if level == 0
      node.each { |child| traverse_depth_first(child, level - 1, &block) }
    end

    def reverse_traverse_depth_first(node = @root, level = @levels, &block)
      return node.reverse_each(&block) if level == 0
      node.reverse_each { |child| reverse_traverse_depth_first(child, level - 1, &block) }
    end

    def leaf_node_for(node, child_index_bits, index)
      return node if child_index_bits == 0
      child_index = (index >> child_index_bits) & INDEX_MASK
      leaf_node_for(node[child_index], child_index_bits - BITS_PER_LEVEL, index)
    end

    def update_root(index, item)
      root, levels = @root, @levels
      while index >= (1 << (BLOCK_SIZE * (levels + 1)))
        root = [root].freeze
        levels += 1
      end
      root = update_leaf_node(root, levels, 0, index, item)
      self.class.alloc(root, @size > index ? @size : index + 1, levels)
    end

    def update_leaf_node(node, levels, depth, index, item)
      slot_index = (index >> ((levels - depth) * BITS_PER_LEVEL)) & INDEX_MASK
      if levels > depth
        old_child = node[slot_index] || []
        item = update_leaf_node(old_child, levels, depth+1, index, item)
      end
      node.dup.tap { |n| n[slot_index] = item }.freeze
    end
  end

  EmptyVector = Hamster::Vector.empty
end
