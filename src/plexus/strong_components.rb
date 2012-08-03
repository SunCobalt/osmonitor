module Plexus
  module StrongComponents
    # strong_components computes the strongly connected components
    # of a graph using Tarjan's algorithm based on DFS. See: Robert E. Tarjan
    # _Depth_First_Search_and_Linear_Graph_Algorithms_. SIAM Journal on 
    # Computing, 1(2):146-160, 1972
    #
    # The output of the algorithm is an array of components where is 
    # component is an array of vertices
    #
    # A strongly connected component of a directed graph G=(V,E) is a maximal
    # set of vertices U which is in V such that for every pair of 
    # vertices u and v in U, we have both a path from u to v 
    # and path from v to u. That is to say that u and v are reachable 
    # from each other.
    #
    def strong_components
      dfs_num    = 0
      stack = []; result = []; root = {}; comp = {}; number = {}

      # Enter vertex callback
      enter = Proc.new do |v| 
        root[v] = v
        comp[v] = :new
        number[v] = (dfs_num += 1)
        stack.push(v)
      end

      # Exit vertex callback
      exit  = Proc.new do |v|
        adjacent(v).each do |w|
          if comp[w] == :new
            root[v] = (number[root[v]] < number[root[w]] ? root[v] : root[w])
          end
        end
        if root[v] == v
          component = []
          begin
            w = stack.pop
            comp[w] = :assigned
            component << w
          end until w == v
          result << component
        end
      end

      # Execute depth first search
      dfs({:enter_vertex => enter, :exit_vertex => exit}); result

    end # strong_components

    # Returns a condensation graph of the strongly connected components
    # Each node is an array of nodes from the original graph
    def condensation
      sc  = strong_components
      cg  = DirectedMultiGraph.new
      map = sc.inject({}) do |a,c| 
        c.each {|v| a[v] = c }; a
      end
      sc.each do |c|
        c.each do |v|
          adjacent(v).each {|v1| cg.add_edge!(c, map[v1]) unless cg.edge?(c, map[v1]) }
        end
      end; 
      cg
    end

    # Compute transitive closure of a graph. That is any node that is reachable
    # along a path is added as a directed edge.
    def transitive_closure!
      cgtc = condensation.plexus_inner_transitive_closure!
      cgtc.each do |cgv|
        cgtc.adjacent(cgv).each do |adj|
          cgv.each do |u| 
            adj.each {|v| add_edge!(u,v)}  
          end
        end
      end; self
    end

    # This returns the transitive closure of a graph. The original graph
    # is not changed.
    def transitive_closure() self.class.new(self).transitive_closure!; end

    def plexus_inner_transitive_closure!  # :nodoc:
      sort.reverse.each do |u| 
        adjacent(u).each do |v|
          adjacent(v).each {|w| add_edge!(u,w) unless edge?(u,w)}
        end
      end; self
    end
  end # StrongComponents
end # Plexus
