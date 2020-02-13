# LODBOOK PLUGIN FOR JEKYLL

This plugin helps create links between narrative text on Jekyll pages
and entities (people, places, events etc) described in a data file.
It creates pages for each of the entities, expresses the relationships
between them as Linked Open Data, and exposes the results as JSONLD and Turtle.

The aim of the plugin was to make it possible for researchers (particularly
historians) to publish data-enriched narratives, and share the products of
their research in a standard format that can be easily preserved and re-used.

----

This plugin was originally based on data_page_generator.rb by Adolfo
Villafiorita, though it has undergone major changes and expansion.

Generate pages from individual records in yml files
(c) 2014-2016 Adolfo Villafiorita

Additions and modifications (c) 2020 Tim Sherratt (@wragge)
Distributed under the conditions of the MIT License

----

## HOW IT WORKS

The process is rather complicated and relies on Jekyll's post-render and
pre-render hooks to create and embed the the LOD.

What you need:

  * One or more Jekyll pages that contain your narrative in Markdown format.
  * A YAML data file that describes the entities in your narrative.

What you do:

  * Markup the narrative text to relate names to records in the data file.
    This is done using a custom tag.
  * Add some config values to describe and organise your entities into
    collections.

What happens when the site is built:

  * The LODBook generator creates page objects for each of the entities in the
    data and adds them to the global site object.
  * The pages containing the narrative text (confusingly Jekyll calls these
    'documents') are rendered. This means the tags that link to entities are
    turned into proper HTML.
  * The post-render hook calls some code that extracts the entity references
    from each narrative page and saves them in the page data for later
    processing. These relationships are also expressed as LOD and embedded
    as JSONLD in the HTML page.
  * The post-render code also generates LOD representations of each page and
    saves them as separate JSONLD and Turtle files.
  * Before the entity pages enter the rendering phase we use their pre-render
    hook to inject some additional data from the narrative pages.
  * Looping through all the entities, we extract any references to them from
    the narrative pages. We also grab a string that shows the name of the
    entity in the context of the page.
  * This data is saved in the page data, converted into LOD, and embedded in
    the HTML. JSONLD and Turtle representations of each page are also created.

All this back and forth means that rich links are established between the
narrative and the data that are both expressed as LOD, and are available to
the site theme to build custom navigation, views, and visualisations.

Complete documentation will be available soon, as well as some sample themes.
