require 'rubygems'
require 'neography'
require 'sinatra'
require 'haml'
require 'cgi'
require 'ruby-tmdb'

Tmdb.api_key = ENV['TMDB_KEY']
Tmdb.default_language = "en"

#require 'net-http-spy'
#Net::HTTP.http_logger_options = {:verbose => true}

neo = Neography::Rest.new(ENV['NEO4J_URL'] || "http://localhost:7474")

def create_graph(neo)
  return if neo.execute_script("g.idx('vertices')[[type:'Movie']].count();").to_i > 0

  if neo.execute_script("g.indices;").empty?  
    neo.execute_script("g.createAutomaticIndex('vertices', Vertex.class, null);") 
    neo.execute_script("AutomaticIndexHelper.reIndexElements(g, g.idx('vertices'), g.V);") if neo.execute_script("g.V.count();").to_i > 0
  end

  begin
    neo.execute_script("g.setMaxBufferSize(1000);

                    'http://neoflix.heroku.com/movies.dat'.toURL().eachLine { def line ->
                       def components = line.split('::');
                       def movieVertex = g.addVertex(['type':'Movie', 'movieId':components[0].toInteger(), 'title':components[1]]);
                       components[2].split('\\\\|').each { def genera ->
                         def hits = g.idx(Tokens.T.v)[[genera:genera]].iterator();
                         def generaVertex = hits.hasNext() ? hits.next() : g.addVertex(['type':'Genera', 'genera':genera]);
                         g.addEdge(movieVertex, generaVertex, 'hasGenera');
                       }
                     };

                     occupations = [0:'other', 1:'academic/educator', 2:'artist',
                       3:'clerical/admin', 4:'college/grad student', 5:'customer service',
                       6:'doctor/health care', 7:'executive/managerial', 8:'farmer',
                       9:'homemaker', 10:'K-12 student', 11:'lawyer', 12:'programmer',
                       13:'retired', 14:'sales/marketing', 15:'scientist', 16:'self-employed',
                       17:'technician/engineer', 18:'tradesman/craftsman', 19:'unemployed', 20:'writer'];

                     'http://neoflix.heroku.com/users.dat'.toURL().eachLine { def line ->
                       def components = line.split('::');
                       def userVertex = g.addVertex(['type':'User', 'userId':components[0].toInteger(), 'gender':components[1], 'age':components[2].toInteger()]);
                       def occupation = occupations[components[3].toInteger()];
                       def hits = g.idx(Tokens.T.v)[[occupation:occupation]].iterator();
                       def occupationVertex = hits.hasNext() ? hits.next() : g.addVertex(['type':'Occupation', 'occupation':occupation]);
                       g.addEdge(userVertex, occupationVertex, 'hasOccupation');
                     };

                     'http://neoflix.heroku.com/ratings.dat'.toURL().eachLine {def line ->
                       def components = line.split('::');
                       def ratedEdge = g.addEdge(g.idx(Tokens.T.v)[[userId:components[0].toInteger()]].next(), g.idx(T.v)[[movieId:components[1].toInteger()]].next(), 'rated');
                       ratedEdge.setProperty('stars', components[2].toInteger());
                       };

                      g.stopTransaction(TransactionalGraph.Conclusion.SUCCESS);")

  rescue Timeout::Error 
    puts "Creating the graph is going to take some time, watch it on #{ENV['NEO4J_URL'] || "http://localhost:7474"}"
  end
end
	

# Begin Neovigator 

  def link_to(url, text=url, opts={})
    attributes = ""
    opts.each { |key,value| attributes << key.to_s << "=\"" << value << "\" "}
    "<a href=\"#{url}\" #{attributes}>#{text}</a>"
  end

  def neighbours
    {"order"         => "depth first",
     "uniqueness"    => "none",
     "return filter" => {"language" => "builtin", "name" => "all_but_start_node"},
     "depth"         => 1}
  end

  def node_id(node)
    case node
      when Hash
        node["self"].split('/').last
      when String
        node.split('/').last
      else
        node
    end
  end

  def get_properties(node)
    properties = "<ul>"
    node["data"].each_pair do |key, value|
        properties << "<li><b>#{key}:</b> #{value}</li>"
      end
    properties + "</ul>"
  end

  def get_poster(node)
    movie = TmdbMovie.find(:title => CGI::escape(node["data"]["title"] || ""), :limit => 1)
    if movie.empty?
     "No Movie Poster found"
    else
      "<img src='#{movie.posters.first.url}'>"
    end
  end

  def get_name(data)
    case data["type"]
      when "Movie"
        "Movie #{data["title"]}"
      when "Occupation"
        "Occupation #{data["occupation"]}"
      when "User"
        "User: #{data["userId"]} Gender: #{data["gender"]} Age: #{data["age"]}"
      when "Genera"
        "Genera #{data["genera"]}"
    end
  end

  def get_recommendations(neo, node)
    rec = neo.execute_script("m = [:];
                              x = [] as Set;
                              g.
                              v(node_id).
                              out('hasGenera').
                              aggregate(x).
                              back(2).
                              inE('rated').
                              filter{it.getProperty('stars') > 3}.
                              outV.
                              outE('rated').
                              filter{it.getProperty('stars') > 3}.
                              inV.
                              filter{it != v}.
                              filter{it.out('hasGenera').toList() == x}.
                              title.
                              groupCount(m);
 
                              m.sort{a,b -> b.value <=> a.value}[0..9];
                             ", {:node_id => node_id(node)})
    return "" if rec == "{}"
    "<ol> #{rec.collect{ |e| "<li>#{e}</li>"}.join(' ')} </ol>"
  end


  get '/resources/show' do
    content_type :json

    node = neo.get_node(params[:id]) 
    connections = neo.traverse(node, "fullpath", neighbours)
    incoming = Hash.new{|h, k| h[k] = []}
    outgoing = Hash.new{|h, k| h[k] = []}
    nodes = Hash.new
    attributes = Array.new

    connections.each do |c|
       c["nodes"].each do |n|
         nodes[n["self"]] = n["data"]
       end
       rel = c["relationships"][0]


       if rel["end"] == node["self"]
         if rel["data"]["stars"].nil?
           incoming["#{rel["type"]}"] << {:values => nodes[rel["start"]].merge({:id => node_id(rel["start"]), :name => get_name(nodes[rel["start"]]) }) }
         else
           incoming["#{rel["type"]} - #{rel["data"]["stars"]} stars"] << {:values => nodes[rel["start"]].merge({:id => node_id(rel["start"]), :name => get_name(nodes[rel["start"]]) }) }
         end
       else
         if rel["data"]["stars"].nil?
           outgoing["#{rel["type"]}"] << {:values => nodes[rel["end"]].merge({:id => node_id(rel["end"]), :name => get_name(nodes[rel["end"]])}) }
         else
           outgoing["#{rel["type"]} - #{rel["data"]["stars"]} stars"] << {:values => nodes[rel["end"]].merge({:id => node_id(rel["end"]), :name => get_name(nodes[rel["end"]])}) }
         end
       end
    end

      incoming.merge(outgoing).each_pair do |key, value|
        attributes << {:id => key, :name => key, :values => value.collect{|v| v[:values]}}
      end

   attributes = [{"name" => "No Relationships","name" => "No Relationships","values" => [{"id" => "#{params[:id]}","name" => "No Relationships "}]}] if attributes.empty?

    @node = {:details_html => "<h2>#{node["data"]["title"]}</h2>" + get_poster(node),
#              :data => {:attributes => node["data"]["title"] ? get_recommendations(neo, node) : attributes, 
              :data => {:attributes => attributes, 
                        :name => get_name(node["data"]),
                        :id => node_id(node)}
            }

    @node.to_json

  end

# End Neovigator 

get '/create_graph' do
  neo.execute_script("g.clear();")
  create_graph(neo)
end

get '/' do
    @neoid = params["neoid"]
    haml :index
end