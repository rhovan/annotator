# Selection and range creation reference for the following code:
# http://www.quirksmode.org/dom/range_intro.html
#
# I've removed any support for IE TextRange (see commit d7085bf2 for code)
# for the moment, having no means of testing it.

$ = jQuery

util =
  getGlobal: -> (-> this)()

  mousePosition: (e, offsetEl) ->
    offset = $(offsetEl).offset()
    {
      top:  e.pageY - offset.top,
      left: e.pageX - offset.left
    }

class Annotator extends Delegator
  events:
    "-adder mousedown":                  "adderMousedown"
    "-highlighter mouseover":            "highlightMouseover"
    "-highlighter mouseout":             "startViewerHideTimer"
    "-viewer mouseover":                 "clearViewerHideTimer"
    "-viewer mouseout":                  "startViewerHideTimer"
    "-editor textarea keydown":          "processEditorKeypress"
    "-editor textarea blur":             "hideEditor"
    "-annotation-controls .edit click":  "controlEditClick"
    "-annotation-controls .del click":   "controlDeleteClick"

    # TODO: allow for adding these events on document.body
    "mouseup":   "checkForEndSelection"
    "mousedown": "checkForStartSelection"

  options:
    classPrefix: "annot" # Class used to identify elements owned/created by the annotator.

    dom:
      adder:       "<div><a href='#'></a></div>"
      editor:      "<div><textarea></textarea></div>"
      highlighter: "<span></span>"
      viewer:      "<div></div>"

  constructor: (element, options) ->
    super

    # Plugin registry
    @plugins = {}

    # Wrap element contents
    @wrapper = $("<div></div>").addClass(this.componentClassname('wrapper'))
    $(@element).wrapInner(@wrapper)
    @wrapper = $(@element).contents().get(0)

    # For all events beginning with '-', map them to a meaningful selector.
    # e.g. '-adder click' -> '.annot-adder click'
    for k, v of @events
      if k[0] is '-'
        @events['.' + @options.classPrefix + k] = v
        delete @events[k]

    # Create model dom elements
    @dom = {}
    for name, src of @options.dom
      @dom[name] = $(src)
        .addClass(this.componentClassname(name))
        .appendTo(@wrapper)
        .hide()

    # Bind delegated events.
    this.addEvents()

  checkForStartSelection: (e) =>
    this.startViewerHideTimer()
    @mouseIsDown = true

  checkForEndSelection: (e) =>
    @mouseIsDown = false

    # This prevents the note image from jumping away on the mouseup
    # of a click on icon.
    if (@ignoreMouseup)
      @ignoreMouseup = false
      return

    this.getSelection()

    s = @selection
    validSelection = s?.rangeCount > 0 and not s.isCollapsed

    if e and validSelection
      @dom.adder
        .css(util.mousePosition(e, @wrapper))
        .show()
    else
      @dom.adder.hide()

  getSelection: ->
    # TODO: fail gracefully in IE.
    @selection = util.getGlobal().getSelection()
    @selectedRanges = (@selection.getRangeAt(i) for i in [0...@selection.rangeCount])

  createAnnotation: (annotation) ->
    a = annotation

    a or= {}
    a.ranges or= @selectedRanges
    a.highlights or= []

    a.ranges = for r in a.ranges
      sniffed    = Range.sniff(r)
      normed     = sniffed.normalize(@wrapper)
      serialized = sniffed.serialize(@wrapper, '.' + this.componentClassname('highlighter'))

    a.highlights = this.highlightRange(normed)

    # Save the annotation data on each highlighter element.
    $(a.highlights).data('annotation', a)
    # Fire annotationCreated event so that others can react to it.
    $(@element).trigger('annotationCreated', [a])

    a

  deleteAnnotation: (annotation) ->
    for h in annotation.highlights
      $(h).replaceWith($(h)[0].childNodes)

    $(@element).trigger('annotationDeleted', [annotation])

  updateAnnotation: (annotation, data) ->
    $.extend(annotation, data)
    $(@element).trigger('annotationUpdated', [annotation])

  loadAnnotations: (annotations, callback) ->
    results = []

    loader = (annList) =>
      now = annList.splice(0,10)

      for n in now
        results.push(this.createAnnotation(n))

      # If there are more to do, do them after a 100ms break (for browser
      # responsiveness).
      if annList.length > 0
        setTimeout((-> loader(annList)), 100)
      else
        callback(results) if callback

    loader(annotations)

  dumpAnnotations: () ->
    if @plugins['Store']
      @plugins['Store'].dumpAnnotations()
    else
      console.warn("Can't dump annotations without Store plugin.")

  highlightRange: (normedRange) ->
    textNodes = $(normedRange.commonAncestor).textNodes()
    [start, end] = [textNodes.index(normedRange.start), textNodes.index(normedRange.end)]
    textNodes = textNodes[start..end]

    elemList = for node in textNodes
      wrapper = @dom.highlighter.clone().show()
      $(node).wrap(wrapper).parent().get(0)

  addPlugin: (name, options) ->
    if @plugins[name]
      console.error "You cannot have more than one instance of any plugin."
    else
      klass = Annotator.Plugins[name]
      if typeof klass is 'function'
        @plugins[name] = new klass(@element, options)
        @plugins[name].annotator = this
      else
        console.error "Could not load #{name} plugin. Have you included the appropriate <script> tag?"
    this # allow chaining

  componentClassname: (name) ->
    @options.classPrefix + '-' + name

  showEditor: (e, annotation) =>
    if annotation
      @dom.editor.data('annotation', annotation)
      @dom.editor.find('textarea').val(annotation.text)

    @dom.editor
      .css(util.mousePosition(e, @wrapper))
      .show()
    .find('textarea')
      .focus()

    $(@element).trigger('annotationEditorShown', [@dom.editor, annotation])

    @ignoreMouseup = true

  hideEditor: ->
    @dom.editor
      .data('annotation', null)
      .hide()
    .find('textarea')
      .val('')

  processEditorKeypress: (e) =>
    if e.keyCode is 27 # "Escape" key => abort.
      this.hideEditor()

    else if e.keyCode is 13 && !e.shiftKey
      # If "return" was pressed without the shift key, we're done.
      this.submitEditor()
      this.hideEditor()

  submitEditor: ->
    textarea = @dom.editor.find('textarea')
    annotation = @dom.editor.data('annotation')

    if annotation
      this.updateAnnotation(annotation, { text: textarea.val() })
    else
      this.createAnnotation({ text: textarea.val() })

  showViewer: (e, annotations) =>
    controlsHTML = """
                   <span class="#{this.componentClassname('annotation-controls')}">
                     <a href="#" class="edit" alt="Edit" title="Edit this annotation">Edit</a>
                     <a href="#" class="del" alt="X" title="Delete this annotation">Delete</a>
                   </span>
                   """

    viewerclone = @dom.viewer.clone().empty()

    for annot in annotations
      # As well as filling the viewer element, we also copy the annotation
      # object from the highlight element to the <div> containing the note
      # and controls. This makes editing/deletion much easier.
      $("""
        <div class='#{this.componentClassname('annotation')}'>
          #{controlsHTML}
          <div class='#{this.componentClassname('annotation-text')}'>
            <p>#{annot.text}</p>
          </div>
        </div>
        """)
        .appendTo(viewerclone)
        .data("annotation", annot)

    viewerclone
      .css(util.mousePosition(e, @wrapper))
      .replaceAll(@dom.viewer).show()

    $(@element).trigger('annotationViewerShown', [viewerclone.get(0), annotations])

    @dom.viewer = viewerclone

  startViewerHideTimer: (e) =>
    # Don't do this if timer has already been set by another annotation.
    if not @viewerHideTimer
      # Allow 250ms for pointer to get from annotation to viewer to manipulate
      # annotations.
      @viewerHideTimer = setTimeout ((ann) -> ann.dom.viewer.hide()), 250, this

  clearViewerHideTimer: () =>
    clearTimeout(@viewerHideTimer)
    @viewerHideTimer = false

  highlightMouseover: (e) =>
    # Cancel any pending hiding of the viewer.
    this.clearViewerHideTimer()

    # Don't do anything if we're making a selection.
    return false if @mouseIsDown

    annotations = $(e.target)
      .parents('.' + this.componentClassname('highlighter'))
      .andSelf()
      .map -> $(this).data("annotation")

    this.showViewer(e, annotations)

  adderMousedown: (e) =>
    @dom.adder.hide()
    this.showEditor(e)
    false

  controlEditClick: (e) =>
    annot = $(e.target).parents('.' + this.componentClassname('annotation'))
    offset = $(@dom.viewer).offset()
    pos =
      pageY: offset.top,
      pageX: offset.left

    # Replace the viewer with the editor.
    @dom.viewer.hide()
    this.showEditor pos, annot.data("annotation")
    false

  controlDeleteClick: (e) =>
    annot = $(e.target).parents('.' + this.componentClassname('annotation'))

    # Delete highlight elements.
    this.deleteAnnotation annot.data("annotation")

    # Remove from viewer and hide viewer if this was the only annotation displayed.
    annot.remove()
    @dom.viewer.hide() unless @dom.viewer.is(':parent')

    false

# Create namespace for Annotator plugins
Annotator.Plugins = {}

# Create global access for Annotator
$.plugin('annotator', Annotator)
this.Annotator = Annotator
