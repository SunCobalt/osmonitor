require 'config'
require 'core'
require 'road_manager'

class BrowseController < ApplicationController
  def road
    @conn = PGconn.open( :host => $config['host'], :dbname => $config['dbname'], :user => $config['user'], :password => $config['password'] )
    @road = nil
    road_manager = RoadManager.new(@conn)
    
    params[:ref].scan(/([^\d]+)(\d+)/i) do |m|
      @road = road_manager.load_road($1, $2)
    end

    @all_ways_wkt = @road.relation_comp_paths[0][0].reduce('') {|s, w| s + w.geom + ','}[0..-2]
    @mark_points_all = @road.relation_comp_end_nodes[0].collect {|node| road_manager.get_node_xy(node.id, @conn)}
    #@mark_points_backward = @road.graph.end_nodes(:BACKWARD).collect {|node| get_node_xy(node.id, @conn)}
    #@mark_points_forward = @road.graph.end_nodes(:FORWARD).collect {|node| get_node_xy(node.id, @conn)}
  end
end