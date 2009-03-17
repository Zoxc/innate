module Innate

  # The nervous system of {Innate}, so you can relax.
  #
  # Node may be included into any class to make it a valid responder to
  # requests.
  #
  # The major difference between this and the old Ramaze controller is that
  # every Node acts as a standalone application with its own dispatcher.
  #
  # What's also an important difference is the fact that {Node} is a module, so
  # we don't have to spend a lot of time designing the perfect subclassing
  # scheme.
  #
  # This makes dispatching more fun, avoids a lot of processing that is done by
  # {Rack} anyway and lets you tailor your application down to the last action
  # exactly the way you want without worrying about side-effects to other
  # {Node}s.
  #
  # Upon inclusion, it will also include {Innate::Trinity} and {Innate::Helper}
  # to provide you with {Innate::Request}, {Innate::Response},
  # {Innate::Session} instances, and all the standard helper methods as well as
  # the ability to simply add other helpers.
  #
  # NOTE:
  #   * Although I tried to minimize the amount of code in here there is still
  #     quite a number of methods left in order to do ramaze-style lookups.
  #     Those methods, and all other methods occurring in the ancestors after
  #     {Innate::Node} will not be considered valid action methods and will be
  #     ignored.
  #   * This also means that method_missing will not see any of the requests
  #     coming in.
  #   * If you want an action to act as a catch-all, use `def index(*args)`.

  module Node
    include Traited

    DEFAULT_HELPERS = %w[aspect cgi flash link partial redirect send_file]
    NODE_LIST = Set.new

    trait(:layout => nil, :alias_view => {}, :provide => {},
          :method_arities => {}, :wrap => [:aspect_wrap], :provide_set => false)

    # Upon inclusion we make ourselves comfortable.
    def self.included(into)
      into.__send__(:include, Helper)
      into.helper(*DEFAULT_HELPERS)

      into.extend(Trinity, self)

      NODE_LIST << into

      return if into.ancestral_trait[:provide_set]
      into.provide(:html, :ERB)
      into.trait(:provide_set => false)
    end

    def self.setup
      NODE_LIST.each{|node| Innate.map(node.mapping, node) }
      Log.debug("Mapped Nodes: %p" % DynaMap.to_hash)
    end

    # Tries to find the relative url that this {Node} is mapped to.
    # If it cannot find one it will instead generate one based on the
    # camel-cased name of itself.
    #
    # @example Usage:
    #
    #   class FooBar
    #     include Innate::Node
    #   end
    #   FooBar.mapping # => '/foo_bar'
    #
    # @return [String] the relative path to the node
    # @see Innate::SingletonMethods#to
    def mapping
      mapped = Innate.to(self)
      return mapped if mapped
      return '/' if NODE_LIST.size == 1
      "/" << self.name.gsub(/\B[A-Z][^A-Z]/, '_\&').downcase
    end

    # Shortcut to map or remap this Node.
    #
    # @example Usage for explicit mapping:
    #
    #   class FooBar
    #     include Innate::Node
    #     map '/foo_bar'
    #   end
    #
    #   Innate.to(FooBar) # => '/foo_bar'
    #
    # @example Usage for automatic mapping:
    #
    #   class FooBar
    #     include Innate::Node
    #     map mapping
    #   end
    #
    #   Innate.to(FooBar) # => '/foo_bar'
    #
    # @param [#to_s] location
    def map(location)
      Innate.map(location, self)
    end

    # Specify which way contents are provided and processed.
    #
    # Use this to set a templating engine, custom Content-Type, or pass a block
    # to take over the processing of the {Action} and template yourself.
    #
    # Provides set via this method will be inherited into subclasses.
    #
    # The +format+ is extracted from the PATH_INFO, it simply represents the
    # last extension name in the path.
    #
    # The provide also has influence on the chosen templates for the {Action}.
    #
    # @example providing RSS with ERB templating
    #
    #   provide :rss, :engine => :ERB
    #
    # Given a request to `/list.rss` the template lookup first tries to find
    # `list.rss.erb`, if that fails it falls back to `list.erb`.
    # If neither of these are available it will try to use the return value of
    # the method in the {Action} as template.
    #
    # A request to `/list.yaml` would match the format 'yaml'
    #
    # @example providing a yaml version of actions
    #
    #   class Articles
    #     include Innate::Node
    #     map '/article'
    #
    #     provide(:yaml, :type => 'text/yaml'){|action, value| value.to_yaml }
    #
    #     def list
    #       @articles = Article.list
    #     end
    #   end
    #
    # @example providing plain text inspect version
    #
    #   class Articles
    #     include Innate::Node
    #     map '/article'
    #
    #     provide(:txt, :type => 'text/plain'){|action, value| value.inspect }
    #
    #     def list
    #       @articles = Article.list
    #     end
    #   end

    def provide(format, options = {}, &block)
      if options.respond_to?(:to_hash)
        options = options.to_hash
        handler = block || View.get(options[:engine])
        content_type = options[:type]
      else
        handler = View.get(options)
      end

      raise(ArgumentError, "Need an engine or block") unless handler

      trait("#{format}_handler"      => handler, :provide_set => true)
      trait("#{format}_content_type" => content_type) if content_type
    end

    def provides
      ancestral_trait.reject{|k,v| k !~ /_handler$/ }
    end

    # This makes the Node a valid application for Rack.
    # +env+ is the environment hash passed from the Rack::Handler
    #
    # We rely on correct PATH_INFO.
    #
    # As defined by the Rack spec, PATH_INFO may be empty if it wants the root
    # of the application, so we insert '/' to make our dispatcher simple.
    #
    # Innate will not rescue any errors for you or do any error handling, this
    # should be done by an underlying middleware.
    #
    # We do however log errors at some vital points in order to provide you
    # with feedback in your logs.
    #
    # NOTE:
    #   * A lot of functionality in here relies on the fact that call is
    #     executed within Innate::STATE.wrap which populates the variables used
    #     by Trinity.
    #   * If you use the Node directly as a middleware make sure that you #use
    #     Innate::Current as a middleware before it.
    #
    # @paran [Hash] env
    #
    # @return [Array]
    #
    # @api external
    # @see Response#reset Node#try_resolve Session#flush
    # @author manveru

    def call(env)
      path = env['PATH_INFO']
      path << '/' if path.empty?

      response.reset
      response = try_resolve(path)

      Current.session.flush(response)

      response.finish
    end

    # Let's try to find some valid action for given +path+.
    # Otherwise we dispatch to action_missing
    #
    # @param [String] path from env['PATH_INFO']
    #
    # @return [Response]
    #
    # @api external
    # @see Node#resolve Node#action_found Node#action_missing
    # @author manveru
    def try_resolve(path)
      action = resolve(path)
      action ? action_found(action) : action_missing(path)
    end

    # Executed once an Action has been found.
    #
    # Reset the {Innate::Response} instance, catch :respond and :redirect.
    # {Action#call} has to return a String.
    #
    # @param [Innate::Action] action
    #
    # @return [Innate::Response]
    #
    # @api external
    # @see Action#call Innate::Response
    # @author manveru
    def action_found(action)
      response = catch(:respond){ catch(:redirect){ action.call }}

      unless response.respond_to?(:finish)
        self.response.write(response)
        response = self.response
      end

      response['Content-Type'] ||= action.options[:content_type]
      response
    end

    # The default handler in case no action was found, kind of method_missing.
    # Must modify the response in order to have any lasting effect.
    #
    # Reasoning:
    # * We are doing this is in order to avoid tons of special error handling
    #   code that would impact runtime and make the overall API more
    #   complicated.
    # * This cannot be a normal action is that methods defined in
    #   {Innate::Node} will never be considered for actions.
    #
    # To use a normal action with template do following:
    #
    # @example
    #
    #   class Hi
    #     include Innate::Node
    #     map '/'
    #
    #     def self.action_missing(path)
    #       return if path == '/not_found'
    #       # No normal action, runs on bare metal
    #       try_resolve('/not_found')
    #     end
    #
    #     def not_found
    #       # Normal action
    #       "Sorry, I do not exist"
    #     end
    #   end
    #
    # @param [String] path
    #
    # @api external
    # @see Innate::Response Node#try_resolve
    # @author manveru
    def action_missing(path)
      response.status = 404
      response['Content-Type'] = 'text/plain'
      response.write("No action found at: %p" % path)

      response
    end

    # Let's get down to business, first check if we got any wishes regarding
    # the representation from the client, otherwise we will assume he wants
    # html.
    #
    # @param [String] path
    #
    # @return [nil Action]
    #
    # @api external
    # @see Node::find_provide Node::update_method_arities Node::find_action
    # @author manveru
    def resolve(path)
      name, wish, engine = find_provide(path)
      action = Action.create(:node => self, :wish => wish, :engine => engine)

      if content_type = ancestral_trait["#{wish}_content_type"]
        action.options = {:content_type => content_type}
      end

      update_method_arities
      fill_action(action, name)
    end

    # Resolve possible provides for the given +path+ from {provides}
    #
    # @param [String] path
    #
    # @return [Array] with name, wish, engine
    #
    # @api internal
    # @see Node::provide Node::provides
    # @author manveru
    def find_provide(path)
      pr = provides

      name, wish, engine = path, 'html', pr['html_handler']

      pr.find do |key, value|
        key = key[/(.*)_handler$/, 1]
        next unless path =~ /^(.+)\.#{key}$/i
        name, wish, engine = $1, key, value
      end

      return name, wish, engine
    end

    # Now we're talking Action, we try to find a matching template and method,
    # if we can't find either we go to the next pattern, otherwise we answer
    # with an Action with everything we know so far about the demands of the
    # client.
    #
    # @param [String] given_name the name extracted from REQUEST_PATH
    # @param [String] wish
    # @author manveru
    def fill_action(action, given_name)
      needs_method = options.needs_method
      wish = action.wish

      patterns_for(given_name) do |name, params|
        method = find_method(name, params)

        next unless method if needs_method
        next unless method if params.any?
        next unless (view = find_view(name, wish)) or method

        action.merge!(:method => method, :view => view, :params => params,
                      :layout => find_layout(name, wish))
      end
    end

    # @param [String] name
    # @param [String] wish
    #
    # @return [Array nil]
    #
    # @api internal
    # @see Node#to_layout Node#find_method Node#find_view
    # @author manveru
    #
    # @todo allow layouts combined of method and view... hairy :)
    def find_layout(name, wish)
      return unless layout = ancestral_trait[:layout]
      return unless layout = layout.call(name, wish) if layout.respond_to?(:call)

      if found = to_layout(layout, wish)
        [:layout, found]
      elsif found = find_view(layout, wish)
        [:view, found]
      elsif found = find_method(layout, [])
        [:method, found]
      end
    end

    # I hope this method talks for itself, we check arity if possible, but will
    # happily dispatch to any method that has default parameters.
    # If you don't want your method to be responsible for messing up a request
    # you should think twice about the arguments you specify due to limitations
    # in Ruby.
    #
    # So if you want your method to take only one parameter which may have a
    # default value following will work fine:
    #
    #   def index(foo = "bar", *rest)
    #
    # But following will respond to /arg1/arg2 and then fail due to ArgumentError:
    #
    #   def index(foo = "bar")
    #
    # Here a glance at how parameters are expressed in arity:
    #
    #   def index(a)                  # => 1
    #   def index(a = :a)             # => -1
    #   def index(a, *r)              # => -2
    #   def index(a = :a, *r)         # => -1
    #
    #   def index(a, b)               # => 2
    #   def index(a, b, *r)           # => -3
    #   def index(a, b = :b)          # => -2
    #   def index(a, b = :b, *r)      # => -2
    #
    #   def index(a = :a, b = :b)     # => -1
    #   def index(a = :a, b = :b, *r) # => -1
    #
    # @todo Once 1.9 is mainstream we can use Method#parameters to do accurate
    #       prediction
    def find_method(name, params)
      return unless arity = trait[:method_arities][name]
      name if arity == params.size or arity < 0
    end

    # Answer with a hash, keys are method names, values are method arities.
    #
    # Note that this will be executed once for every request, once we have
    # settled things down a bit more we can switch to update based on Reloader
    # hooks and update once on startup.
    # However, that may cause problems with dynamically created methods, so
    # let's play it safe for now.
    #
    # @example
    #
    #   Hi.update_method_arities
    #   # => {'index' => 0, 'foo' => -1, 'bar => 2}
    #
    # @see Node::resolve
    # @return [Hash] mapping the name of the methods to their arity
    def update_method_arities
      arities = {}
      trait(:method_arities => arities)

      exposed = ancestors & Helper::EXPOSE.to_a
      higher = ancestors.select{|a| a < Innate::Node }

      (higher + exposed).reverse_each do |ancestor|
        ancestor.public_instance_methods(false).each do |im|
          arities[im.to_s] = ancestor.instance_method(im).arity
        end
      end

      arities
    end

    # Try to find the best template for the given basename and wish.
    #
    # @param [#to_s] file
    # @param [#to_s] wish
    #
    # @see Node#to_template
    # @author manveru
    def find_view(file, wish)
      aliased = find_aliased_view(file, wish)
      return aliased if aliased

      to_template([app_root, app_view, view_root, file], wish)
    end

    # This is done to make you feel more at home, pass an absolute path or a
    # path relative to your application root to set it, otherwise you'll get
    # the current mapping.
    def view_root(location = nil)
      location ? (@view_root = location) : (@view_root ||= Innate.to(self))
    end

    # Get or set the path(s) to the layout directory relative to {app_root}
    #
    # @param [String Array] location
    #
    # @return [String Array]
    #
    # @api external
    # @see Node#layout Node#find_layout Node#to_layout Node#app_layout
    # @author manveru
    def layout_root(location = nil)
      location ? (@layout_root = location) : (@layout_root ||= '/')
    end

    # Aliasing one view from another.
    # The aliases are inherited, and the optional third +node+ parameter
    # indicates the Node to take the view from.
    #
    # The argument order is identical with `alias` and `alias_method`, which
    # quite honestly confuses me, but at least we stay consistent.
    #
    # @example
    #   class Foo
    #     include Innate::Node
    #
    #     # Use the 'foo' view when calling 'bar'
    #     alias_view 'bar', 'foo'
    #
    #     # Use the 'foo' view from FooBar node when calling 'bar'
    #     alias_view 'bar', 'foo', FooBar
    #   end
    #
    # Note that the parameters have been simplified in comparision with
    # Ramaze::Controller::template where the second parameter may be a
    # Controller or the name of the template.  We take that now as an optional
    # third parameter.
    #
    # @param [#to_s]      to   view that should be replaced
    # @param [#to_s]      from view to use or Node.
    # @param [#nil? Node] node optionally obtain view from this Node
    #
    # @api external
    # @see Node::find_aliased_view
    # @author manveru
    def alias_view(to, from, node = nil)
      trait[:alias_view] || trait(:alias_view => {})
      trait[:alias_view][to.to_s] = node ? [from.to_s, node] : from.to_s
    end

    # Resolve one level of aliasing for the given +file+ and +wish+.
    #
    # @param [String] file
    # @param [String] wish
    #
    # @return [nil String] the absolute path to the aliased template or nil
    #
    # @api internal
    # @see Node::alias_view Node::find_view
    # @author manveru
    def find_aliased_view(file, wish)
      aliased_file, aliased_node = ancestral_trait[:alias_view][file]
      aliased_node ||= self
      aliased_node.find_view(aliased_file, wish) if aliased_file
    end

    # Find the best matching file for the layout, if any.
    #
    # This is mostly an abstract method that you might find handy if you want
    # to do vastly different layout lookup.
    #
    # @param [String] file
    # @param [String] wish
    #
    # @return [nil String] the absolute path to the template or nil
    #
    # @api internal
    # @see Node::to_template
    # @author manveru
    def to_layout(file, wish)
      to_template([app_root, app_layout, layout_root, file], wish)
    end

    # Define a layout to use on this Node.
    #
    # A Node can only have one layout, although the template being chosen can
    # depend on {provides}.
    #
    # @param [String #to_s] name basename without extension of the layout to use
    # @param [Proc #call] block called on every dispatch if no name given
    #
    # @return [Proc String] The assigned name or block
    #
    # @api external
    # @see Node#find_layout Node#layout_root Node#to_layout Node#app_layout
    # @author manveru
    #
    # NOTE:
    #   The behaviour of Node#layout changed significantly from Ramaze, instead
    #   of multitudes of obscure options and methods like deny_layout we simply
    #   take a block and use the returned value as the name for the layout. No
    #   layout will be used if the block returns nil.
    def layout(name = nil, &block)
      if name and block
        trait(:layout => lambda{|n, w| name if block.call(n, w) })
      elsif name
        trait(:layout => name.to_s)
      elsif block
        trait(:layout => block)
      end

      return ancestral_trait[:layout]
    end

    # The innate beauty in Nitro, Ramaze, and {Innate}.
    #
    # Will yield the name of the action and parameter for the action method in
    # order of significance.
    #
    #   def foo__bar # responds to /foo/bar
    #   def foo(bar) # also responds to /foo/bar
    #
    # But foo__bar takes precedence because it's more explicit.
    #
    # The last fallback will always be the index action with all of the path
    # turned into parameters.
    #
    # @example yielding possible combinations of action names and params
    #
    #   class Foo; include Innate::Node; map '/'; end
    #
    #   Foo.patterns_for('/'){|action, params| p action => params }
    #   # => {"index"=>[]}
    #
    #   Foo.patterns_for('/foo/bar'){|action, params| p action => params }
    #   # => {"foo__bar"=>[]}
    #   # => {"foo"=>["bar"]}
    #   # => {"index"=>["foo", "bar"]}
    #
    #   Foo.patterns_for('/foo/bar/baz'){|action, params| p action => params }
    #   # => {"foo__bar__baz"=>[]}
    #   # => {"foo__bar"=>["baz"]}
    #   # => {"foo"=>["bar", "baz"]}
    #   # => {"index"=>["foo", "bar", "baz"]}
    #
    # @param [String #split] path usually the PATH_INFO
    #
    # @return [Action] it actually returns the first non-nil/false result of yield
    #
    # @see Node#fill_action
    # @api internal
    # @author manveru
    def patterns_for(path)
      atoms = path.split('/')
      atoms.delete('')
      result = nil

      atoms.size.downto(0) do |len|
        action = atoms[0...len].join('__')
        params = atoms[len..-1]
        action = 'index' if action.empty?

        return result if result = yield(action, params)
      end

      return nil
    end

    # Try to find a template at the given +path+ for +wish+.
    #
    # Since Innate supports multiple paths to templates the +path+ has to be an
    # Array that may be nested one level.
    # The +path+ is then translated by {Node#path_glob} and the +wish+ by
    # {Node#ext_glob}.
    #
    # @example Usage to find available templates
    #
    #   # This assumes following files:
    #   # view/foo.erb
    #   # view/bar.erb
    #   # view/bar.rss.erb
    #   # view/bar.yaml.erb
    #
    #   class FooBar
    #     Innate.node('/')
    #   end
    #
    #   FooBar.to_template(['.', 'view', '/', 'foo'], 'html')
    #   # => "./view/foo.erb"
    #   FooBar.to_template(['.', 'view', '/', 'foo'], 'yaml')
    #   # => "./view/foo.erb"
    #   FooBar.to_template(['.', 'view', '/', 'foo'], 'rss')
    #   # => "./view/foo.erb"
    #
    #   FooBar.to_template(['.', 'view', '/', 'bar'], 'html')
    #   # => "./view/bar.erb"
    #   FooBar.to_template(['.', 'view', '/', 'bar'], 'yaml')
    #   # => "./view/bar.yaml.erb"
    #   FooBar.to_template(['.', 'view', '/', 'bar'], 'rss')
    #   # => "./view/bar.rss.erb"
    #
    # @param [Array] path possibly nested array containing strings
    # @param [String] wish
    #
    # @return [nil String] relative path to the first template found
    #
    # @api external
    # @see Node#find_view Node#to_layout Node#find_aliased_view
    #      Node#path_glob Node#ext_glob
    # @author manveru
    def to_template(path, wish)
      return unless exts = ext_glob(wish)
      glob = "#{path_glob(*path)}.#{exts}"
      found = Dir[glob].uniq

      count = found.size
      Log.warn("%d views found for %p" % [count, glob]) if count > 1

      found.first
    end

    # Produce a glob that can be processed by Dir::[] matching the possible
    # paths to the given +elements+.
    #
    # The +elements+ are an Array that may be nested one level, take care to
    # splat if you try to pass an existing Array.
    #
    # @return [String] glob matching possible paths to the given +elements+
    #
    # @api internal
    # @see Node#to_template
    # @author manveru
    def path_glob(*elements)
      File.join(elements.map{|element|
        "{%s}" % [*element].map{|e| e.to_s.gsub('__', '/') }.join(',')
      }).gsub(/\/\{\/?\}\//, '/')
    end

    # Produce a glob that can be processed by Dir::[] matching the extensions
    # associated with the given +wish+.
    #
    # @param [#to_s] wish the extension (no leading '.')
    #
    # @return [String] glob matching the valid exts for the given +wish+
    #
    # @api internal
    # @see Node#to_template View::exts_of Node#provides
    # @author manveru
    def ext_glob(wish)
      pr = provides
      return unless engine = pr["#{wish}_handler"]
      engine_exts = View.exts_of(engine).join(',')
      represented = [*wish].map{|k| "#{k}." }.join(',')
      "{%s,}{%s}" % [represented, engine_exts]
    end

    # This awesome piece of hackery implements action AOP, methods may register
    # themself in the trait[:wrap] and will be called in left-to-right order,
    # each being passed the action instance and a block that they have to yield
    # to continue the chain.
    #
    # This enables things like action logging, caching, aspects,
    # authentication, etc...
    #
    # @param [Action] action instance that is being passed to every registered method
    # @param [Proc] block contains the instructions to call the action method if any
    # @see Action#render
    # @author manveru
    def wrap_action_call(action, &block)
      wrap = ancestral_trait[:wrap]
      head, *tail = wrap
      tail.reverse!
      combined = tail.inject(block){|s,v| lambda{ __send__(v, action, &s) } }
      __send__(head, action, &combined)
    end

    # For compatibility with new Kernel#binding behaviour in 1.9
    #
    # @return [Binding] binding of the instance being rendered.
    # @see Action#binding
    # @author manveru
    def binding; super end

    def app_root; options[:root] end
    def app_view; options[:view] end
    def app_layout; options[:layout] end
  end

  module SingletonMethods
    # Convenience method to include the Node module into +node+ and map to a
    # +location+.
    #
    # @param [#to_s]    location where the node is mapped to
    # @param [Node nil] node     the class that will be a node, will try to look it
    #                            up if not given
    # @return [Class] the node argument or detected class will be returned
    # @see Innate::node_from_backtrace
    # @author manveru
    def node(location, node = nil)
      node ||= node_from_backtrace(caller)
      node.__send__(:include, Node)
      node.map(location)
      node
    end

    # Cheap hack that works reasonably well to avoid passing self all the time
    # to Innate::node
    # We simply search the file that Innate::node was called in for the first
    # class definition above the line that Innate::node was called and look up
    # the constant.
    # If there are any problems with this (filenames containing ':' or
    # metaprogramming) just pass the node parameter explicitly to Innate::node
    #
    # @param [Array #[]] backtrace
    # @see Innate::node
    # @author manveru
    def node_from_backtrace(backtrace)
      file, line = backtrace[0].split(':', 2)
      line = line.to_i
      File.readlines(file)[0..line].reverse.find{|line| line =~ /^\s*class\s+(\S+)/ }
      const_get($1)
    end
  end
end
