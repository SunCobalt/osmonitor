#!/usr/bin/ruby

require 'net/http'
require 'erb'
require 'media_wiki'
require 'pg'

require './config'
require './osm'
require './pg_db'
require './elogger'
require './wiki'

if ARGV.size == 0
  puts "Usage: road_report.rb <input page> <output page>"
  exit
elsif ARGV.size == 1
  @input_page = @output_page = ARGV[0]
else
  @input_page = ARGV[0]
  @output_page = ARGV[1]
end

TABLE_HEADER_MARKER = "<!-- OSMonitor HEADER -->"
TABLE_CELL_MARKER = "<!-- OSMonitor REPORT -->"
TIMESTAMP_BEGIN = "<!-- OSMonitor TIMESTAMP -->"
TIMESTAMP_END = "<!-- OSMonitor /TIMESTAMP -->"
OK_COLOR = "PaleGreen"
ERROR_COLOR = "LightSalmon"
WARNING_COLOR = "PaleGoldenrod"

@mw = MediaWiki::Gateway.new('https://wiki.openstreetmap.org/w/api.php')

#@log = EnhancedLogger.new("osmonitor.log")
@log = EnhancedLogger.new(STDOUT)
@log.level = Logger::DEBUG

@status_template = ERB.new File.read("erb/road_status.erb")

@conn = PGconn.open( :host => "localhost", :dbname => 'osmdb', :user => "postgres" )

def render_issue_template(file, issue, status)
  return ERB.new(File.read("#{file}")).result(binding())
end

def tables_to_roads(page)
  roads = []

  page.tables.each do |table|
    if ! table.table_text.include?("{{PL")
      @log.debug "Table with no roads - next"
      next
    end

    table.rows.each do |row|
      m = row.row_text.scan(/PL\-(\w+)\|(\d+)/)

      if $1 and $2
        road = Road.new($1, $2, row)

        # Now let's try to parse input length for the road.
        length_text = row.cells[2].cell_text.strip.gsub('km', '').gsub(',', '.')
        road.input_length = length_text.to_f if !length_text.empty?
        roads << road
      end
    end
  end

  return roads
end

def fill_road_relation(road)

	sql_select = "SELECT *, OSM_GetRelationLength(r.id) AS length, OSM_IsMostlyCoveredBy(936128, r.id) AS covered
FROM relations r
WHERE
  r.tags -> 'type' = 'route' AND
  r.tags -> 'route' = 'road' AND
"

  sql = {}

  sql["A"]=<<-EOF
  (r.tags -> 'ref' ilike '#{road.ref_prefix + road.ref_number}' OR replace(r.tags -> 'ref', ' ', '') ilike '#{road.ref_prefix + road.ref_number}')
    EOF

  sql["S"]=<<-EOF
  (r.tags -> 'ref' ilike '#{road.ref_prefix + road.ref_number}' OR replace(r.tags -> 'ref', ' ', '') ilike '#{road.ref_prefix + road.ref_number}')
    EOF

  sql["DK"]=<<-EOF
  ((r.tags -> 'ref' ilike '#{road.ref_prefix + road.ref_number}' OR replace(r.tags -> 'ref', ' ', '') ilike '#{road.ref_prefix + road.ref_number}') OR
  (r.tags -> 'ref' = '#{road.ref_number}'))
    EOF

  sql["DW"]=<<-EOF
  ((r.tags -> 'ref' ilike '#{road.ref_prefix + road.ref_number}' OR replace(r.tags -> 'ref', ' ', '') ilike '#{road.ref_prefix + road.ref_number}') OR
  (r.tags -> 'ref' = '#{road.ref_number}'))
    EOF

  query = sql_select + sql[road.ref_prefix] + " ORDER BY covered DESC"

  #puts query

  result = @conn.query(query).collect { |row| process_tags(row) }

  road.relation = result[0] if result.size > 0
  road.other_relations = result[1..-1] if result.size > 1
end

def prepare_page(page)
  page.tables.each do |table|
    next if table.table_text.include?(TABLE_HEADER_MARKER)
    table.add_column_header(TABLE_HEADER_MARKER + "Bot report")
    table.add_cell(TABLE_CELL_MARKER)
  end
end

def generate_status_text(status)
  text = @status_template.result(binding)
  text.gsub!(/^\s*$/, '')
  text.gsub!("\n\n", "\n")
  return text
end

def insert_relation_id(status)
  return if ! status.road.relation

  new_row = status.road.row.row_text.dup
  new_row.gsub!(/{{relation\|\d*}}/im, "{{relation\|#{status.road.relation['id']}}}")
  status.road.row.update_text(new_row)
end

def remove_relation_id(status)
  new_row = status.road.row.row_text.dup.gsub(/{{relation\|\d*[}]+/im, "{{relation|}}")
  status.road.row.update_text(new_row)
end

def fill_road_status(status)
  return if !status.road.row.row_text.include?(TABLE_CELL_MARKER)

  status.validate

  color = OK_COLOR
  color = WARNING_COLOR if status.get_issues(:WARNING).size > 0
  color = ERROR_COLOR if status.get_issues(:ERROR).size > 0

  status.road.row.set_background_color(color)

  if status.road.relation
    insert_relation_id(status)
  else
    remove_relation_id(status)
  end

  new_row = status.road.row.row_text.dup
  new_row.gsub!(/#{Regexp.escape(TABLE_CELL_MARKER)}.*/im, TABLE_CELL_MARKER + generate_status_text(status) + "\n")
  status.road.row.update_text(new_row)
end

def get_data_timestamp
  return @conn.query("SELECT OSM_GetDataTimestamp()").getvalue(0, 0)
end

def insert_data_timestamp(page)
  page.page_text.gsub!(/#{Regexp.escape(TIMESTAMP_BEGIN)}.*?#{Regexp.escape(TIMESTAMP_END)}/,
    TIMESTAMP_BEGIN + get_data_timestamp + TIMESTAMP_END)
end

def run_report
  page = get_wiki_page(@input_page)
  page_text = page.page_text.dup

  prepare_page(page)
  insert_data_timestamp(page)

  roads = tables_to_roads(page)

  @log.debug "Got #{roads.size} road(s)"

  roads.each_with_index do |road, i|
    status = RoadStatus.new(road)
    fill_road_relation(road)

    @log.debug("Processing road #{road.ref_prefix + road.ref_number} (#{i + 1} of #{roads.size}) (input length = #{road.input_length})")

    before = Time.now
    fill_ways(road, @conn)
    @log.debug("fill_ways took #{Time.now - before}")

    if road.relation
      before = Time.now
      fill_relation_ways(road, @conn)
      @log.debug("fill_relation_ways took #{Time.now - before}")

      components, visited = road_connected(road, @conn)

      @log.debug("components = #{components}, has_proper_network = #{road.has_proper_network}, % = #{road.percent_with_lanes}")

      status.connected = components == 1
      status.components = components
    end

    fill_road_status(status)
  end

  wiki_login
  edit_wiki_page(@output_page, page.page_text)
end

def road_connected(road, conn)
  return false if ! road.relation

  @nodes = {}
  before = Time.now

  @conn.query("
SELECT distinct wn.node_id AS id
FROM relation_members rm
INNER JOIN way_nodes wn ON (wn.way_id = rm.member_id AND rm.relation_id = #{road.relation['id']})
--INNER JOIN nodes n ON (n.id = wn.node_id)
      ").each do |row|
    row["tags"] = "'a'=>2"
    @nodes[row["id"].to_i] = OSM::Node[[0,0], row]
  end

  @conn.query("SELECT DISTINCT node_id, ARRAY(SELECT DISTINCT
                wn_neigh.node_id
        FROM  way_nodes wn_neigh
        WHERE wn_neigh.way_id = wn.way_id AND (wn_neigh.sequence_id = wn.sequence_id - 1 OR wn_neigh.sequence_id = wn.sequence_id + 1)
        ) AS neighs
FROM way_nodes wn
INNER JOIN relation_members rm ON (rm.member_id = way_id AND rm.relation_id = #{road.relation['id']})
    ").each do |row|
      row['neighs'].gsub!('{','[')
      row['neighs'].gsub!('}',']')
      @nodes[row["node_id"].to_i].neighs += eval(row['neighs']).collect {|x| x.to_i}
  end

  @log.debug "road_connected: query took #{Time.now - before}"

  before = Time.now
  *a = bfs(@nodes)
  @log.debug "bfs took #{Time.now - before} (#{@nodes.size})"

  return a
end

def fill_relation_ways(road, conn)
  return false if ! road.relation

  @nodes = {}
  before = Time.now

  road.relation_ways = conn.query("
SELECT distinct w.*
FROM relation_members rm
INNER JOIN ways w ON (w.id = rm.member_id)
WHERE rm.relation_id = #{road.relation['id']}").collect { |row| process_tags(row) }
end

def fill_ways(road, conn)
  return false if ! road.relation

  @nodes = {}
  before = Time.now

  road.ways = conn.query("
SELECT distinct w.*
FROM ways w
WHERE tags -> 'ref' = '#{road.ref_number}'
      ").collect { |row| process_tags(row) }
end

def bfs(nodes, start_node = nil)
  return {} if nodes.empty?
  visited = {}
  i = 0

  #puts nodes

  while (visited.size < nodes.size)
    #puts "#{visited.size} <? #{nodes.size}"
    i += 1

    before = Time.now

    if i == 1 and start_node
      next_root = start_node
    else
      candidates = (nodes.keys - visited.keys)
      next_root = candidates[0]
      c = 0

      while ! nodes.include?(next_root)
        c += 1
        next_root = [c]
      end
    end

    #@log.debug("candidate choice took #{Time.now - before}")

    visited[next_root] = i
    queue = [next_root]
    
    puts "------------------ INCREASING i to #{i}, next_root = #{next_root}"
    
    count = 0

    while(!queue.empty?)
      node = queue.pop()
      #puts "visiting #{node}"
      #puts nodes[node]
      nodes[node].neighs.each do |neigh|
        #puts "neigh #{neigh} visited - #{visited.has_key?(neigh)}"
        if ! visited.has_key?(neigh) and nodes.include?(neigh) then
           queue.push(neigh)
           visited[neigh] = i
           count += 1
         end
      end
    end
  end

  return i, visited
end

def process_tags(row)
  row['tags'] = eval("{#{row['tags']}}")
  return row
end

def get_wiki_page(name)
  return WikiPage.new(@mw.get name)
end

def edit_wiki_page(name, body)
  @mw.create(name, body, :overwrite => true, :summary => 'Automated')
end

def wiki_login
  @mw.login(@config['wiki_username'], @config['wiki_password'])
end

run_report
