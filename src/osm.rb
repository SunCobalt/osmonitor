require "./wiki"

$relation_networks = { "A" => "pl:motorways", "S" => "pl:national", "DK" => "pl:national", "DW" => "pl:regional" }

def get_relation_network(prefix)
  return $relation_networks[prefix]
end

class Road
  attr_accessor :ref_prefix
  attr_accessor :ref_number
  attr_accessor :relation
  attr_accessor :other_relations
  attr_accessor :row
  attr_accessor :relation_ways
  attr_accessor :ways

  def initialize(ref_prefix, ref_number, row)
    self.ref_prefix = ref_prefix
    self.ref_number = ref_number
    self.row = row
    self.other_relations = []
    self.relation_ways = []
    self.ways = []
  end

  def get_network
    return (relation and relation["tags"]["network"])
  end

  def get_proper_network
    return get_relation_network(ref_prefix)
  end

  def has_proper_network
    return get_network == get_proper_network 
  end

  def has_many_relations
    return !other_relations.empty?
  end

  def has_many_covered_relations
    return other_relations.select {|x| x['covered'] == 't'}.size > 0
  end

  def percent_with_lanes
    return if not relation_ways or relation_ways.empty?
    return ((relation_ways.select { |way| way['tags'].has_key?('lanes') }.size / relation_ways.size.to_f) * 100).to_i
  end

  def percent_with_maxspeed
    return if not relation_ways or relation_ways.empty?
    return ((relation_ways.select { |way| way['tags'].has_key?('maxspeed') }.size / relation_ways.size.to_f) * 100).to_i
  end
end

class RoadStatus
  attr_accessor :road
  attr_accessor :connected
  attr_accessor :components

  def initialize(road)
    self.road = road
  end
end

module OSM

  module Taggable
    attr_accessor :tags
    private
    def init_tags(tags)
      @tags = tags
    end
  end

  module Element
    attr_accessor :element_id, :changeset_id, :timestamp, :visible, :version, :uid
    private
    def init_attrs(attrs)
      @element_id = attrs[:id]
      @changeset_id = attrs[:changeset]
      @timestamp = attrs[:timestamp]
      @visible = attrs.has_key?(:visible) ? attrs[:visible] : true
      @version = attrs[:version]
      @uid = attrs[:uid]
    end

    def self.parse_options(options)
      options = options.merge(eval("{" + options["tags"] + "}"))
      groups = options.group_by {|k, v| k.instance_of? String and v.instance_of? String}
      tags = groups[true].nil? ? Hash.new : Hash[groups[true]]
      attrs = groups[false].nil? ? Hash.new : Hash[groups[false]]
      return tags, attrs
    end

    def compare(o, arg, *args)
      cmp = self.send(arg) <=> o.send(arg)
      if cmp != 0 or args.empty?
        cmp
      else
        compare(o, *args)
      end
    end
  end

  class Node
    include Taggable, Element, Comparable

    attr_accessor :position
    attr_accessor :neighs

    @neighs = []

    def self.[](pos, options = {})
      tags, attrs = Element.parse_options(options)
      Node.new(attrs, pos, tags)
    end

    def <=>(o)
      compare(o, :position, :tags, :element_id, :changeset_id, :timestamp, :visible, :version)
    end

    def to_s
      self.class.to_s + "[" + 
        @position.inspect + "," + 
        [:element_id, :changeset_id, :timestamp, :visible, :version].collect {|attr| "#{attr.inspect}=>#{self.send(attr)}"}.join(",") + "," + 
        @tags.to_a.collect {|k,v| "#{k.inspect}=>#{v.inspect}"}.join(",") + "]"
    end

    def version_zero_geom
      # there's no real "version zero" geometry for a node - it's
      # not possible to have one where the geometry is not a valid
      # lon/lat pair. so here we choose something which can't 
      # happen in the real data model.
      nil
    end

    def geom
      position
    end

    def geom=(pos)
      @position = pos
    end

    def version_zero
      Node[version_zero_geom, :id => self.element_id, :version => 0]
    end

    def invalid?
      @position == version_zero_geom
    end

    private
    def initialize(attrs, pos, tags)
      @position = pos
      @neighs = []
      init_attrs(attrs)
      init_tags(tags)
    end
  end

  class Way
    include Taggable, Element, Comparable

    attr_accessor :nodes

    def self.[](nodes, options = {})
      tags, attrs = Element.parse_options(options)
      Way.new(attrs, nodes, tags)
    end

    def <=>(o)
      compare(o, :nodes, :tags, :element_id, :changeset_id, :timestamp, :visible, :version)
    end

    def to_s
      self.class.to_s + "[" + 
        @nodes.inspect + "," + 
        [:element_id, :changeset_id, :timestamp, :visible, :version].collect {|attr| "#{attr.inspect}=>#{self.send(attr)}"}.join(",") + "," + 
        @tags.to_a.collect {|k,v| "#{k.inspect}=>#{v.inspect}"}.join(",") + "]"
    end

    def version_zero_geom
      # according to the "version zero" proposal, we should start
      # by assuming a zeroth version which is simply empty.
      []
    end

    def geom
      nodes
    end

    def geom=(n)
      @nodes = n
    end

    def version_zero
      Way[version_zero_geom, :id => self.element_id, :version => 0]
    end

    def invalid?
      @nodes.size < 2
    end

    private
    def initialize(attrs, nodes, tags)
      @nodes = nodes
      init_attrs(attrs)
      init_tags(tags)
    end
  end


  class Relation
    include Taggable, Element, Comparable

    class Member
      include Comparable

      attr_accessor :type, :ref, :role

      def self.[](type, ref, role = "")
        if type.class == String then
          type = OSM::Node if type == 'node'
          type = OSM::Way if type == 'way'
          type = OSM::Relation if type == 'relation'
        end
        Member.new(type, ref, role)
      end

      def <=>(o)
        return @type.name <=> o.type.name if @type != o.type
        return @ref <=> o.ref if @ref != o.ref
        @role <=> o.role
      end

      def hash
        [@type, @ref, @role].hash
      end

      def eql?(o)
        @type.eql?(o.type) &&
          @ref.eql?(o.ref) &&
          @role.eql?(o.role)
      end

      def to_s
        "Member[#{@type.inspect},#{@ref},#{@role.inspect}]"
      end

      private
      def initialize(type, ref, role)
        @type, @ref, @role = type, ref, role
      end
    end

    attr_accessor :members

    def self.[](members, options = {})
      tags, attrs = Element.parse_options(options)
      Relation.new(attrs, members, tags)
    end

    def <=>(o)
      compare(o, :members, :tags, :element_id, :changeset_id, :timestamp, :visible, :version)
    end

    def to_s
      self.class.to_s + "[" + 
        @members.inspect + "," + 
        [:element_id, :changeset_id, :timestamp, :visible, :version].collect {|attr| "#{attr.inspect}=>#{self.send(attr)}"}.join(",") + "," + 
        @tags.to_a.collect {|k,v| "#{k.inspect}=>#{v.inspect}"}.join(",") + "]"
    end

    def version_zero_geom
      # according to the "version zero" proposal, we should start
      # by assuming a zeroth version which is simply empty.
      return []
    end

    def geom
      members
    end

    def geom=(m)
      @members = m
    end

    def version_zero
      Relation[version_zero_geom, :id => self.element_id, :version => 0]
    end

    def invalid?
      @members.length < 1
    end

    private
    def initialize(attrs, members, tags)
      @members = members.map {|m| Member[*m]}
      init_attrs(attrs)
      init_tags(tags)
    end
  end
end
