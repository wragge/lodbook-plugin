# frozen_string_literal: true

#
# This a modified version of data_page_generator.rb by Adolfo Villafiorita.
#
# Generate pages from individual records in yml files
# (c) 2014-2016 Adolfo Villafiorita
#
# Additions and modifications (c) 2016 Tim Sherratt (@wragge)
# Distributed under the conditions of the MIT License

# Two possible data sources -- YAML and JSON-LD
# For YAML, supply context in config
# For JSON-LD context will be in data

# So it seems as if the pre/post rendering happens in groups rather than across the site:
# 1. Generators (create data pages)
# 2. documents (the narrative bits) -- prerender, then postrender
# 3. pages (generated from data file) -- prerender, then postrender
# So prerender phase of pages will access postrender version of documents...

module Jekyll
    # Namespace for the LODBook plugin
    module LODBook
        require 'json/ld'
        # Preload to save time
        ctx = JSON::LD::Context.new.parse('http://schema.org/')
        JSON::LD::Context.add_preloaded('http://schema.org/', ctx)

        # --------------------
        # UTILITIES
        # --------------------
        # Some general LOD utilities
        module Utilities
            # Get the LOD context
            def get_context(site)
                # Set current context
                # Order:
                # 1. context in config
                # 2. context in JSONLD
                # 3. default (schema)
                # Note that you could therefore use a specific context in config
                # to remap context (eg coming from Omeka) -- I think?
                # Need to check all this to allow for complex contexts and namespaces
                lod_source = site.config['lod_source']
                data = site.data[lod_source['data']]
                context = if lod_source.key?('context')
                              # Get context from config
                              # Will this work with multiple, namespaced context values?
                              lod_source['context']
                          # If we're working with JSON-LD it might already have a context value
                          elsif data.is_a?(Hash) && data.key?('@context')
                              data['@context']
                          else
                              # Default context
                              'http://schema.org/'
                          end
                context
            end

            # Get the LOD data payload
            def get_graph(site)
                # lod_source are the data config details
                # data is the parsed data file
                # context = get_context(lod_source, data)
                # if this is JSON-LD it'll be a hash with a 'graph' key
                # But will it? No. Maybe.
                # Explicitly state the data type in config -- YAML, JSON-LD, & possibly CSV?
                context = get_context(site)
                data = site.data[site.config['lod_source']['data']]
                if data.is_a?(Hash) && data.key?('@graph')
                    # if JSON-LD, compact the data
                    str_context = context.is_a?(String) ? context : JSON.parse(context.to_json)
                    # Not sure if this is really necessary, but it ensures a standard format
                    compact = compact_jsonld(str_context, data)
                    # Won't necessarily have a graph value -- only if there originally
                    # Need to change this??
                    graph = compact['@graph']
                else
                    graph = data
                end
                graph
            end

            # Return LOD context and data payload
            def parse_data(site)
                context = get_context(site)
                graph = get_graph(site)
                { context: context, graph: graph }
            end

            def compact_jsonld(context, data)
                lod = JSON.parse(data.to_json)
                # Not sure if this is really necessary, but it ensures a standard format
                expanded = JSON::LD::API.expand(lod)
                # Should this be flattened rather than compacted? No I think flattening it changes the structure
                JSON::LD::API.compact(expanded, context)
            end

            # NOT USED??
            def format_url(context, name, collection)
                @site_url = context.registers[:site].config['url']
                @base_url = context.registers[:site].config['baseurl']
                "#{@site_url}#{@base_url}/#{collection}/#{Utils.slugify(name)}/"
            end

            def create_entity_uri(site, collection, entity_name)
                site_url = site.config['url']
                base_url = site.config['baseurl']
                filename = Utils.slugify(entity_name)
                "#{site_url}#{base_url}/#{collection}/#{filename}/"
            end

            def get_record(data, name)
                data.find { |r| r['name'] == name }
            end
        end

        # Things to run before the entity pages are rendered
        # Gets mentions from the narrative pages and inserts them into LOD
        # and makes them available to HTML page for display
        module PagePreRender
            include Utilities

            def remove_tags(str)
                str.gsub(%r{<\/?[^>]*>}, '')
            end

            def get_keyword_string(str, first, last)
                remove_tags(str).split[first..last]&.join(' ')
            end

            def extract_context_from_match(para, anchor, index, number_of_words = 5)
                before = get_keyword_string(para.inner_html[0..index - 1], 0 - number_of_words, -1)
                after = get_keyword_string(para.inner_html[index + anchor.length..-1], 0, number_of_words)
                "#{before} <em>#{remove_tags(anchor)}</em> #{after}".strip
            end

            def extract_mentions_from_para(document, para_id, para, anchor)
                mentions = []
                para.inner_html.scan(/#{anchor}/) do
                    index = Regexp.last_match.offset(0)[0]
                    context = extract_context_from_match(para, anchor, index)
                    # Save the details of each context
                    mentions << {
                        'document_title' => document.data['title'], 'document_chapter' => document.data['chapter'],
                        'document_url' => document.url, 'para' => para_id, 'context' => context
                    }
                end
                mentions
            end

            def extract_anchors_from_para(para, name)
                anchors = []
                # Find all links to this entity in the current para
                para.css("a[data-name=\"#{name}\"]").each do |link|
                    anchors |= [link.to_html]
                end
                anchors
            end

            def extract_mentions_from_page(document, name)
                mentions = []
                html = Nokogiri::HTML(document.output)
                html.css('#text  p').each do |para|
                    # Get the id of the para
                    para_id = para.attr('id').split('-')[1]
                    anchors = extract_anchors_from_para(para, name)
                    # Find all links to this entity in the current para

                    # puts keyword
                    # para = link.parent
                    # para.text.scan(/.*{50}(?=#{keyword})(?<=#{keyword}).*{50}/)[0].split[0,5].join(' ')
                    # Now loop through all the links extracting 5 words wither side to give the context
                    anchors.each do |anchor|
                        mentions += extract_mentions_from_para(document, para_id, para, anchor)
                    end
                end
                mentions
            end

            def are_there_mentions(document, page)
                data = document.data
                config = page.site.config
                entity_id = "#{config['url']}#{config['baseurl']}#{page.url}"
                return unless data.key?('data') && data['data']['mentions'].find { |r| r['id'] == entity_id }

                { 'id' => data['data']['id'], 'name' => data['title'], 'type' => 'WebPage' }
            end

            def update_jsonld(page, lod)
                compacted = compact_jsonld(page.data['data']['@context'], lod)
                jsonld_page = page.site.pages.find { |p| p.url == "#{page.url}index.json" }
                jsonld_page.content = JSON.pretty_generate(compacted)
            end

            def update_turtle(page, lod)
                turtle = page.site.pages.find { |p| p.url == "#{page.url}index.ttl" }
                graph = RDF::Graph.new << JSON::LD::API.toRdf(lod)
                turtle.content = graph.dump(:ttl)
            end

            def update_lod(page, mentioned_by, mentions)
                # Save the details of pages that mention this thing into the data
                page.data['data']['mentionedBy'] = mentioned_by unless mentioned_by.empty?
                # Save the contexts in which this thing is mentioned into the data
                page.data['contexts'].concat(mentions) unless mentions.empty?
                # Add LOD representation of this thing to the JSONLD and Turtle versions created earlier
                lod = JSON.parse(page.data['data'].to_json)
                update_turtle(page, lod)
                update_jsonld(page, lod)
            end

            def enrich_page(page)
                return unless page.data.key?('data')

                mentions = []
                mentioned_by = []
                # collection, _id = page.url.split('/')
                # Loop through the narrative pages for any references to this entity
                page.site.documents.each do |document|
                    # If there's one or more references to this entity in this page
                    # we'll extract information about them
                    mentioned = are_there_mentions(document, page)
                    next unless mentioned

                    mentioned_by << mentioned
                    # Now look at the content of the page to find where this thing is mentioned
                    mentions = extract_mentions_from_page(document, page.data['title'])
                end
                update_lod(page, mentioned_by, mentions)
            end
        end

        # Class to help in preparing LOD
        class GraphMaker
            require 'json/ld'
            include Utilities
            attr_reader :graph

            def initialize(site)
                @site = site
                # lod_source = site.config['lod_source']
                # data_source = site.data[lod_source['data']]
                @types = site.config['data_types']
                @data = get_graph(@site)
                @graph = {}
            end

            def process_record2(properties)
                # puts properties
                @graph << extract_properties_from_record(properties)
            end

            # Convert record to LOD
            # Data is expected to be a hash
            def convert_to_lod(data)
                data.each do |key, value|
                    @graph.merge!(extract_properties(data, key, value))
                end
            end

            def extract_properties(parent, key, value)
                if value.is_a?(Hash)
                    process_hash(key, value)
                elsif value.is_a?(Array)
                    process_array(key, value)
                else
                    process_value(parent, key, value)
                end
            end

            # Process string and URI values
            def process_value(parent, key, value)
                properties = {}
                if key == 'name'
                    properties['name'] = value
                    # If the value doesn't already have an id or type, create one from the name
                    properties.merge!(hydrate_link(parent, value))
                    # Normalise type and id labels
                else
                    properties = normalise_label(key, value, properties)
                end
                properties
            end

            def normalise_label(key, value, properties)
                if key == 'type'
                    properties['@type'] = @types.key?(value) ? @types[value]['type'] : value
                elsif key == 'id'
                    properties['@id'] = value
                else
                    properties[key] = value
                end
                properties
            end

            def process_array(key, value)
                values = []
                value.each do |v|
                    values.push(extract_properties(value, key, v))
                end
                { key => collapse_array(values) }
            end

            def process_hash(key, value)
                properties = {}
                value.each do |k, v|
                    properties.merge!(extract_properties(value, k, v))
                end
                { key => properties }
            end

            def collapse_array(values)
                values.map(&:values)
            end

            def get_type(record)
                @types[record['type']]['type']
            end

            # Add properties to link
            def add_link_properties(parent, name, record)
                unless parent.key?('id') || parent.key?('@id')
                    id = create_entity_uri(@site, @types[record['type']]['collection'], name)
                end
                type = get_type(record)
                link = { 'name': name, '@id' => id, '@type' => type }
                link['image'] = record['image'] if link['@type'].include?('ImageObject') && record.key?('image')
                link
            end

            # Relationships are defined using name properties
            # Here we'll expand and LODify the link info by adding additional properties
            # such as id and type.
            def hydrate_link(parent, name)
                record = get_record(name)
                if record
                    link = add_link_properties(parent, name, record)
                else
                    puts "\e[31mNot found -- #{name}\e[0m"
                    link = { 'name': name }
                end
                link
            end

            def get_record(prop)
                # Retrieve a data record using it's name property
                @data.find { |r| r['name'] == prop }
            end
        end

        # Class for text/narrative pages.
        class ContentPage
            require 'nokogiri'
            include Utilities

            attr_reader :html

            def initialize(document)
                @site = document.site
                @page = document
                @context = get_context(@site)
                @data = get_graph(@site)
                @html = Nokogiri::HTML(document.output)
                @references = {}
                @page_data = document.data
            end

            # Collects data from HTML links that have been created by
            # the LODLink tag at an earlier processing stage
            def collect_references
                @html.css('#text p').each do |para|
                    para.css('a[property=name]').each do |link|
                        @references[link.content] = {
                            'url': link['href'],
                            'name': link['data-name'],
                            'collection': link['data-collection']
                        }
                    end
                end
            end

            # Add numeric ids to ps and blockquotes, so they can be referenced in JS interface-y stuff.
            def number_paras
                @html.css('#text p').each_with_index do |para, index|
                    para['id'] = "para-#{index}"
                end
                @html.css('blockquote').each_with_index do |quote, index|
                    quote['id'] = "quote-#{index}"
                end
            end

            # Add HTML links to other instances of the labels marked up by LODLink tags.
            def markup_labels
                labels = @references.keys.sort_by(&:length).reverse!
                @html.css('#text p').each do |para|
                    labels.each do |label|
                        markup_para(para, label)
                    end
                end
            end

            def markup_para(para, label)
                para.children.each do |child|
                    next if child[:class] == 'lod-link' || child[:class] == 'lod-ignore'

                    markup_child_node(child, para, label)
                end
            end

            def markup_child_node(child, para, label)
                link = create_link_for_markup(label)
                if child.text? && child.content.include?(label)
                    # Adding this dummy node stops the new content merging into the old
                    dummy = child.add_previous_sibling(Nokogiri::XML::Node.new('dummy', para))
                    # Create node for marked up content
                    dummy.add_previous_sibling child.content.gsub(/\b#{label}\b/, "#{link}#{label}</a>")
                    # Add marked up content to node
                    # new_child.inner_html = child.content.gsub(/\b#{label}\b/, "#{link}#{label}</a>")
                    # Remove old nodes
                    child.remove
                    dummy.remove
                elsif child.text == label
                    child.inner_html = "#{link}#{child.inner_html}</a>"
                end
            end

            def create_link_for_markup(label)
                name = @references[label][:name]
                collection = @references[label][:collection]
                url = @references[label][:url]
                "<a class=\"lod-link\" data-name=\"#{name}\""\
                " data-collection=\"#{collection}\" property=\"name\""\
                " href=\"#{url}\">"
            end

            # Look up the names in the data set, and LODify their details
            def mentions_as_lod
                names = names_from_references
                mentions = []
                names.each do |name|
                    record = get_record(name)
                    graph_maker = GraphMaker.new(@site)
                    graph_maker.convert_to_lod(record)
                    mentions |= [graph_maker.graph]
                end
                mentions
            end

            # Collect the names of all the entities referred to in this page.
            def names_from_references
                names = []
                @references.each do |_key, reference|
                    names |= [reference[:name]]
                end
                names
            end

            def create_page_id
                site_url = @site.config['url']
                base_url = @site.config['baseurl']
                "#{site_url}#{base_url}#{@page.url}"
            end

            def create_page_jsonld
                mentions = mentions_as_lod
                page_name = "Chapter #{@page.data['chapter']}: #{@page.data['title']}"
                lod_mentions = {
                    '@id' => create_page_id,
                    'name': page_name,
                    '@type' => 'WebPage',
                    'mentions' => mentions
                }
                lod = { '@context' => @context, '@graph' => lod_mentions }
                compact_jsonld(@context, lod)
            end

            # Add LOD to the page that includes details of all the entities mentioned by it.
            def add_jsonld
                jsonld = create_page_jsonld
                script = Nokogiri::HTML.fragment(
                    "<script id=\"page-data\" type=\"application/ld+json\">#{JSON.pretty_generate(jsonld)}</script>"
                )
                @html.css('body')[0].add_child(script)
                jsonld
            end

            def get_record(prop)
                @data.find { |r| r['name'] == prop }
            end

            def add_styles
                css = ''
                @site.config['data_collections'].each do |collection|
                    coll_name = collection['name']
                    coll_colour = collection['color']
                    css += ".#{coll_name} { background-color: #{coll_colour}; border-color: #{coll_colour}}\n"
                    css += ".#{coll_name}.inverse { background-color: #ffffff; color: #{coll_colour}}\n"
                end
                style = Nokogiri::HTML.fragment("<style type=\"text/css\">#{css}</style>")
                @html.css('head')[0].add_child(style)
            end
        end

        # --------------------
        # GENERATORS
        # --------------------

        # Generates pages (aka documents) for each of the entities in the data file.
        class DataPagesGenerator < Generator
            safe true
            include Utilities
            require 'rdf/turtle'
            require 'json/ld'

            # Generate a page for each record in the data file
            def generate(site)
                puts "\n\e[34mMAKING ENTITY PAGES:\e[0m"
                @site = site
                @types = site.config['data_types']
                @context = get_context(site)
                records = get_graph(site)
                # records is the list of records defined in _data.yml
                # for which we want to generate different pages
                records.each do |record|
                    process_record(record)
                end
            end

            def process_record(record)
                type = record['type']
                if @types[type]
                    collection = @types[type]['collection'] || type
                    template = @types[type]['template']
                    lod = create_graph(collection, record)
                    jsonld = compact_jsonld(@context, lod)
                    make_pages(collection, jsonld, template, record['name'])
                else
                    puts "\e[31mType not configured: #{type}\e[0m"
                end
            end

            def make_pages(collection, jsonld, template, name)
                @site.pages << DataPage.new(@site, @site.source, collection, jsonld, template)
                @site.pages << TurtlePage.new(@site, @site.source, collection, name)
                @site.pages << JSONPage.new(@site, @site.source, collection, name)
            end

            def create_graph(collection, record)
                puts 'Making graph'
                # Convert record hash into LOD
                graph_maker = GraphMaker.new(@site)
                graph_maker.convert_to_lod(record)[0]
                graph = graph_maker.graph
                # puts graph
                # Create page URI
                page_id = create_entity_uri(@site, collection, record['name'])
                # Make sure the record has an id
                graph['@id'] = page_id unless record.key?('@id')
                # Relate entity to HTML page
                graph['mainEntityofPage'] = "#{page_id}index.html"
                lod = { '@context': @context, '@graph': graph }
                # This is needed to parse as LOD
                JSON.parse(lod.to_json)
            end
        end

        # --------------------
        # DATA PAGES
        # Classes used in the generation of entity pages and LOD representations (JSONLD & Turtle)
        # --------------------

        # Class for an entity HTML page, used by DataPagesGenerator.
        class DataPage < Page
            # - `dir` is the default output directory
            # - `data` is the data defined in `_data.yml` of the record for which we are generating a page
            # - `template` is the name of the template for generating the page

            def initialize(site, base, dir, data, template)
                @site = site
                page_name = data['name']
                puts page_name
                @dir = "#{dir}/#{Utils.slugify(page_name)}/"
                @name = 'index.html'
                process(@name)
                read_yaml(File.join(base, '_layouts'), template + '.html')
                self.data['title'] = page_name
                self.data['data'] = data
                self.data['contexts'] = []
                # add all the information defined in _data for the current record to the
                # current page (so that we can access it with liquid tags)
                # self.data.merge!(data)
                # puts 'Finished'
            end
        end

        # Class for an RDF Turtle representation of the entity, used by DataPagesGenerator.
        # Content gets added later when the entity page goes through pre-render.
        # This is so we can pick up mentions from the rendered narrative pages.
        class TurtlePage < Page
            def initialize(site, base, collection, entity_name)
                @site = site
                filename = Utils.slugify(entity_name)
                @dir = "#{collection}/#{filename}/"
                @name = 'index.ttl'
                process(@name)
                read_yaml(File.join(base, '_layouts'), 'text.md')
            end
        end

        # Class for a JSON-LD representation of the entity, used by DataPagesGenerator
        # Content gets added later when the entity page goes through pre-render.
        # This is so we can pick up mentions from the rendered narrative pages.
        class JSONPage < Page
            def initialize(site, base, collection, entity_name)
                @site = site
                filename = Utils.slugify(entity_name)
                @dir = "#{collection}/#{filename}/"
                @name = 'index.json'
                process(@name)
                read_yaml(File.join(base, '_layouts'), 'text.md')
            end
        end

        # Class for a RDF Turtle representation of a narrative page, called by postrender hook
        class TurtleContentPage < Page
            def initialize(site, base, dir, data, template)
                @site = site
                @dir = dir
                # Create the page using these built-in methods
                process('index.ttl')
                read_yaml(File.join(base, '_layouts'), template + '.md')
                # Convert the JSON data to Turtle
                graph = RDF::Graph.new << JSON::LD::API.toRdf(data)
                # Add the data to the page
                self.data['lod'] = graph.dump(:ttl)
            end
        end

        # Class for a JSON-LD representation of a narrative page, called by postrender hook
        class JSONContentPage < Page
            def initialize(site, base, dir, data, template)
                @site = site
                @dir = dir
                # Create the page using these built-in methods
                process('index.json')
                read_yaml(File.join(base, '_layouts'), template + '.md')
                # Add the data to the page
                self.data['lod'] = JSON.pretty_generate(data)
            end
        end

        # --------------------
        # BLOCK TAGS
        # --------------------

        # Turns {% lod %} tags in text into HTML linked to entity pages.
        class LODLink < Liquid::Block
            include Utilities

            def initialize(tag_name, name, tokens)
                super
                @name = name.strip
            end

            def format_link(context, record, label)
                base_url = context.registers[:site].config['baseurl']
                types = context.registers[:site].config['data_types']
                collection = types[record['type']]['collection']
                url = "#{base_url}/#{collection}/#{Utils.slugify(@name)}/"
                "<a class=\"lod-link\" data-name=\"#{@name}\" data-collection=\"#{collection}\""\
                " property=\"name\" href=\"#{url}\">#{label}</a>"
            end

            def render(context)
                @name = super.to_s if @name == ''
                # puts @name
                data = get_graph(context.registers[:site])
                record = get_record(data, @name)
                # puts record
                if record
                    format_link(context, record, super.to_s)
                else
                    puts "\e[31m#{@name} not found\e[0m"
                    super.to_s
                end
            end
        end

        # Tag to markup names you don't want to be LOD-ified.
        class LODIgnore < Liquid::Block
            def initialize(tag_name, params, tokens)
                super
            end

            def render(context)
                "<span class=\"lod-ignore\">#{super}</span>"
            end
        end

        # --------------------
        # FILTERS
        # --------------------

        # Gets the filename for an image.
        module ImageLink
            def image_link(image)
                if image&.is_a?(Hash)
                    find_image_file(image)
                else
                    check_extension(image)
                end
            end

            def check_extension(image)
                extension = File.extname(image)
                if ['.jpg', '.png', '.gif', '.jpeg'].include?(extension.downcase)
                    image
                elsif ['.tif', '.tiff', '.pdf'].include?(extension.downcase)
                    puts "\e[31mImage not processed: #{image}\e[0m"
                end
            end

            def find_image_file(image)
                image_name = image['name']
                return unless image_name

                data = get_graph(@context.registers[:site])
                record = get_record(data, image_name)
                if record && record['image']
                    record['image']
                else
                    puts "\e[31mImage not found: #{image_name}\e[0m"
                end
            end
        end

        # Is this being used anywhere?
        module ImageLinks
            def add_image_links(things)
                things.each do |thing|
                    next unless thing['image']

                    image_file = image_link(thing['image'])
                    thing['image_file'] = image_file if image_file
                end
                things
            end
        end

        # Formats an ISO date as a nice human-readable string
        module FormatDate
            def format_date(date)
                formatted_date = date.to_s
                parts = date.to_s.split('-')
                if parts.length == 3
                    formatted_date = Date.iso8601(date).strftime('%e %B %Y')
                elsif parts == 2
                    formatted_date = Date.iso8601(date + '-01').strftime('%B %Y')
                end
                formatted_date
            end
        end

        # Formats a complete URI when supplied with a name and collection.
        # Use in lists etc. For example:
        # {% for knows in page.data.knows %}
        # <li><a href="{{ knows.name | lod_url: "", knows.collection }}">{{ knows.name }}</a></li>
        # {% endfor %}
        module LODUrlFilter
            def lod_url(name, collection)
                site_url = context.registers[:site].config['url']
                base_url = context.registers[:site].config['baseurl']
                "#{site_url}#{base_url}/#{collection}/#{Utils.slugify(name)}/"
            end
        end

        # Shuffle an array to allow for random selections
        module ShuffleFilter
            def shuffle(array)
                array.shuffle
            end
        end

        # Creates JSON-LD about an entity for embedding in a page.
        # Converts 'name' & 'collection' pairs to '@id's.
        # Wraps the JSON-LD in script tags.
        #
        # Feed it a page and get back JSON-LD wrapped in a script tag -- eg: {{ page | jsonldify }}
        # TURN THIS INTO A BLOCK TAG?????
        module JSONLDGenerator
            require 'yaml'
            # require 'json'
            require 'json/ld'
            include LODUrlFilter
            include Utilities

            def jsonldify(data)
                "<script type=\"application/ld+json\">\n#{JSON.pretty_generate(data)}\n</script>"
            end
        end

        # Return the collection that this record is a part of
        module CollectionFilter
            def collection(record)
                types = @context.registers[:site].config['data_types']
                types[record['type']]['collection']
            end
        end

        # Output a HTML formatted list item from LOD item
        module LODItem
            include Utilities

            def create_link_for_item(value)
                name = value['name']
                record = get_record(@data, name)
                if record
                    collection = @site.config['data_types'][record['type']]['collection']
                    "<a href=\"#{@site.config['baseurl']}/#{collection}/#{Utils.slugify(name)}/\">#{name}</a>\n"
                else
                    name
                end
            end

            def process_hash_value(value)
                if value.key?('name') && !value.key?('id')
                    create_link_for_item(value)
                elsif value.key?('id') && value.key?('name')
                    "<a href=\"#{value['id']}\">#{value['name']}</a>\n"
                elsif value.key?('id')
                    "<a href=\"#{value['id']}\">#{value['id']}</a>\n"
                end
            end

            def lod_item(value)
                @site = @context.registers[:site]
                @data = get_graph(@context.registers[:site])
                if value.is_a?(Hash)
                    process_hash_value(value)
                else
                    value
                end
            end
        end

        # Creates a HTML list of values for a particular property
        module LODList
            include Utilities
            include LODItem

            def list_unknown_properties(value)
                output = ''
                value.each do |k, v|
                    output += "<li>#{k}: #{v}</li>\n"
                end
                output
            end

            def process_hash_value(value)
                if value.key?('name') && !value.key?('id')
                    "<li>#{create_link_for_item(value)}</li>"
                elsif value.key?('id') && value.key?('name')
                    "<li><a href=\"#{value['id']}\">#{value['name']}</a></li>\n"
                elsif value.key?('id')
                    "<li><a href=\"#{value['id']}\">#{value['id']}</a></li>\n"
                else
                    list_unknown_properties(value)
                end
            end

            def format_item(value)
                if value.is_a?(Hash)
                    process_hash_value(value)
                elsif value =~ /^(http|https)/
                    "<li><a href=\"#{value}\">#{value}</a></li>\n"
                else
                    "<li>#{value}</li>\n"
                end
            end

            def generate_html_list(label, list)
                output = "<h4 class='title lod-list-title'>#{label.capitalize}</h4>\n<ul class='lod-list'>\n"
                if list.is_a?(Array)
                    list.each do |value|
                        output += format_item(value)
                    end
                else
                    output += format_item(list)
                end
                output += "</ul>\n"
                output
            end

            def lod_list(list, label)
                @site = @context.registers[:site]
                # @site_url = @context.registers[:site].config['url']
                # @base_url = @context.registers[:site].config['baseurl']
                # @types = @context.registers[:site].config['data_types']
                @data = get_graph(@context.registers[:site])
                # Dunno why I had this complicated capitlization stuff
                # if label[0..0] =~ /[a-z]/
                #    label = label.gsub(/[A-Z]/, ' \0').capitalize
                #    label = label.gsub(/\w+/) {|word| word.capitalize}
                # end
                generate_html_list(label, list) if list
            end
        end
    end
end

# pre render documents to tag additional mentions, then add mentions to page data

# So it seems as if the pre/post rendering happens in groups rather than across the site:
# 1. Generators
# 2. documents (the narrative bits) -- prerender, then postrender
# 3. pages (generated from data file) -- prerender, then postrender
# So prerender phase of pages will access postrender version of documents...

# --------------------
# HOOKS
# --------------------

Jekyll::Hooks.register :pages, :pre_render do |page|
    require 'nokogiri'
    include Jekyll::LODBook::PagePreRender
    # This adds more details into the pages for individual entities
    # This runs after the documents have been rendered.
    # So we can get some info from documents about where things are mentioned and insert them in the page data / lod.
    enrich_page(page)
end

Jekyll::Hooks.register :documents, :post_render do |document|
    puts "\n\e[34mENRICHING NARRATIVE PAGE: #{document['title']}\e[0m"
    require 'nokogiri'
    include Jekyll::LODBook
    include Jekyll::Utils
    content_page = ContentPage.new(document)
    # base_url = document.site.config['base_url']
    # lod_source = document.site.config['lod_source']
    # data_source = document.site.data[lod_source['data']]
    # types = document.site.config['data_types']
    # data = get_graph(lod_source, data_source)
    # html = Nokogiri::HTML(document.output)
    content_page.number_paras
    content_page.collect_references
    content_page.markup_labels
    lod = content_page.add_jsonld
    # content_page.add_styles()
    document.output = content_page.html.to_html
    # This is so we can pick up the mentions later in pages
    document.data['data'] = lod
    document.site.pages << JSONContentPage.new(document.site, document.site.source, document.url, lod, 'text')
    document.site.pages << TurtleContentPage.new(document.site, document.site.source, document.url, lod, 'text')
end

# --------------------
# REGISTER TAGS AND FILTERS
# --------------------

Liquid::Template.register_tag('lod', Jekyll::LODBook::LODLink)
Liquid::Template.register_tag('lod_ignore', Jekyll::LODBook::LODIgnore)
Liquid::Template.register_filter(Jekyll::LODBook::LODUrlFilter)
Liquid::Template.register_filter(Jekyll::LODBook::JSONLDGenerator)
Liquid::Template.register_filter(Jekyll::LODBook::LODList)
Liquid::Template.register_filter(Jekyll::LODBook::LODItem)
Liquid::Template.register_filter(Jekyll::LODBook::ImageLink)
Liquid::Template.register_filter(Jekyll::LODBook::ImageLinks)
Liquid::Template.register_filter(Jekyll::LODBook::FormatDate)
Liquid::Template.register_filter(Jekyll::LODBook::ShuffleFilter)
Liquid::Template.register_filter(Jekyll::LODBook::CollectionFilter)
