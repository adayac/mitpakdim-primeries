root = window.mit ?= {}

############### UTILITIES ##############

String::repeat = ( num ) ->
    new Array( num + 1 ).join( this )

############### JQUERY UI EXTENSIONS ##############

$.widget "mit.agendaSlider", $.extend({}, $.ui.slider.prototype, {
    _create : (->
            cached_old_slider_create = $.ui.slider::_create
            new_create_func = ->
                @element.append '<div class="ui-slider-mid-marker"></div>'
                cached_old_slider_create.apply @
            new_create_func
        )()
    setCandidateMarker : (value) ->
        candidate_marker_classname = "ui-slider-candidate-marker"
        if not @element.find(".#{candidate_marker_classname}").length
            handle = @element.find(".ui-slider-handle")
            handle.before "<div class='#{candidate_marker_classname}'></div>"
        @element.find(".#{candidate_marker_classname}").css
            left : value + "%"
})

############### SYNC ##############

root.syncEx = (options_override) ->
    (method, model, options) ->
        Backbone.sync(method, model, _.extend({}, options, options_override))

root.JSONPCachableSync = (callback_name) ->
    root.syncEx
        cache: true
        dataType: 'jsonp'
        jsonpCallback: callback_name or 'cachable'

root.syncOptions =
    dataType: 'jsonp'

# Assume a repo has a key named objects with a list of objects identifiable by an id key
smartSync = (method, model, options) ->
    options = _.extend {}, root.syncOptions, model.syncOptions, options
    getLocalCopy = ->
        repo = options.repo
        repo = if _.isString(repo) then root[repo] else repo
        if method isnt 'read' or not repo
            return null
        if model instanceof Backbone.Collection
            return repo
        # Assume could only be a Model
        _.where(repo.objects, id: model.id)[0]

    if localCopy = _.clone getLocalCopy()
        promise = $.Deferred()
        _.defer ->
            if _.isFunction options.success
                options.success localCopy, null # xhr
            promise.resolve localCopy, null
        return promise
    return (options.sync or Backbone.sync)(method, model, options)

############### MODELS ##############

class root.MiscModel extends Backbone.Model
class root.Agenda extends Backbone.Model
    defaults:
        uservalue: 0

class root.Candidate extends Backbone.Model
    defaults:
        score: 'N/A'
        participating: true

    getAgendas: ->
        if @agendas_fetching.state() != "resolved"
            console.log "Trying to use candidate agendas before fetched", @, @agendas_fetching
            throw "Agendas not fetched yet!"
        @get('agendas')

    initialize: ->
        @agendas_fetching = $.Deferred()

        set_default = (attr, val) =>
            # Good for not sharing same object for all instances
            if @get(attr) is undefined
                @set(attr, val)
        set_default 'recommendation_positive', {}
        set_default 'recommendation_negative', {}

class root.Member extends root.Candidate
    class MemberAgenda extends Backbone.Model
        urlRoot: "http://www.oknesset.org/api/v2/member-agendas/"
        url: ->
            super(arguments...) + '/'
        sync: =>
            root.JSONPCachableSync("memberagenda_#{ @id }")(arguments...)
        getAgendas: ->
            ret = {}
            _.each @get('agendas'), (agenda) ->
                ret[agenda.id] = agenda.score
            ret

    fetchAgendas: (force) ->
        if @agendas_fetching.state() != "resolved" or force
            @memberAgendas = new MemberAgenda
                id: @id
            @memberAgendas.fetch
                success: =>
                    @set 'agendas', @memberAgendas.getAgendas()
                    @agendas_fetching.resolve()
                error: =>
                    console.log "Error fetching member agendas", @, arguments
                    @agendas_fetching.reject()

        return @agendas_fetching

class root.Newbie extends root.Candidate
    initialize: ->
        super(arguments...)
        @agendas_fetching.resolve()

class root.Recommendation extends Backbone.Model

############### COLLECTIONS ##############

class root.JSONPCollection extends Backbone.Collection
    sync: smartSync
    initialize: ->
        super(arguments...)
    parse: (response) ->
        return response.objects

class root.PartyList extends root.JSONPCollection
    model: root.MiscModel
    url: "http://www.oknesset.org/api/v2/party/"
    syncOptions:
        repo: window.mit.party

class root.AgendaList extends root.JSONPCollection
    model: root.Agenda
    url: "http://www.oknesset.org/api/v2/agenda/"
    syncOptions:
        repo: window.mit.agenda

class root.MemberList extends root.JSONPCollection
    model: root.Member
    url: "http://www.oknesset.org/api/v2/member/?extra_fields=current_role_descriptions,party_name"
    syncOptions:
        repo: window.mit.member
        sync: root.JSONPCachableSync('members')

    sync: (method, model, options) ->
        members_options = _.extend {}, options,
            success: undefined,
            error: undefined,
        members = smartSync(method, model, options)

        extra_options = _.extend {}, members_options,
            repo: window.mit.member_extra
            url: "data/member_extra.jsonp"
        extra = smartSync(method, model, extra_options)

        $.when(members, extra).done (orig_args, extra_args) ->
            extendArrayWithId = (dest, sources...) ->
                for src in sources
                    for item in src
                        id = item.id
                        if dest_item = _.where(dest, id: id)[0]
                            _.extend dest_item, item
                        else
                            dest.push item
            extendArrayWithId orig_args[0].objects, extra_args[0].objects

            if _.isFunction options.success
                options.success orig_args...
        .fail (orig_args, extra_args) ->
            if _.isFunction options.error
                options.error orig_args...

    fetchAgendas: ->
        fetches = []
        @each (member) =>
            fetches.push member.fetchAgendas()
        console.log "Waiting for " + fetches.length + " member agendas"
        @agendas_fetching = $.when(fetches...)
        .done =>
            console.log "Got results!", this, arguments
        .fail =>
            console.log "Error getting results!", this, arguments

class root.NewbiesList extends root.JSONPCollection
    model: root.Newbie
    syncOptions:
        repo: window.mit.combined_newbies
    url: "http://www.mitpakdim.co.il/site/primaries/data/newbies.jsonp"
    fetchAgendas: ->
        @agendas_fetching = $.Deferred().resolve()

class root.RecommendationList extends root.JSONPCollection
    model: root.Recommendation
    syncOptions:
        repo: window.mit.recommendations
    url: "http://www.mitpakdim.co.il/site/primaries/data/recommendations.jsonp"

############### VIEWS ##############

class root.TemplateView extends Backbone.View
    template: ->
        _.template( @get_template() )(arguments...)
    render: =>
        @$el.html( @template(@model.toJSON()) )
        @

class root.ListViewItem extends root.TemplateView
    tagName: "div"
    get_template: ->
        "<a href='#'><%= name %></a>"
    events:
        'click': ->
            @trigger 'click', @model

class root.CandidateView extends root.ListViewItem
    className: "candidate_instance"
    initialize: ->
        super(arguments...)
        @model.on 'change', =>
            console.log 'candidate changed: ', @, arguments
            @render()
    get_template: ->
        $("#candidate_template").html()


class root.ListView extends root.TemplateView
    initialize: ->
        super(arguments...)
        @options.itemView ?= root.ListViewItem
        @options.autofetch ?= true
        if @options.collection
            @setCollection(@options.collection)

    setCollection: (collection) ->
        @collection = collection
        @collection.on "add", @addOne
        @collection.on "reset", @addAll
        if @options.autofetch
            @collection.fetch()
        else
            @addAll()

    addOne: (modelInstance) =>
        view = new @options.itemView({ model:modelInstance })
        view.on 'all', @itemEvent
        @$el.append view.render().$el

    addAll: =>
        @initEmptyView()
        @collection.each(@addOne)

    initEmptyView: =>
        @$el.empty()

    itemEvent: =>
        @trigger arguments...


class root.DropdownItem extends Backbone.View
    tagName: "option"
    render: =>
        json = @model.toJSON()
        @$el.html( json.name )
        @$el.attr({ value: json.id })
        @

class root.DropdownContainer extends root.ListView
    tagName: "select"
    options:
        itemView: root.DropdownItem,
        show_null_option: true
    initEmptyView: =>
        if @options.show_null_option
            @$el.html("<option>-----</option>")
    events: 'change': ->
        @trigger 'change', @collection.at (@$el.children().index @$('option:selected')) - 1

class root.CandidatesMainView extends Backbone.View
    el: ".candidates_container"
    initialize: ->
        @membersView = new root.CandidateListView
            el: ".members"
            collection: @.options.members
        @newbiesView = new root.CandidateListView
            el: ".newbies"
            collection: @.options.newbies

        @membersView.on 'all', @propagate
        @newbiesView.on 'all', @propagate

    propagate: =>
        @trigger arguments...

root.CandidatesMainView.create_delegation = (func_name) ->
    delegate = ->
        @membersView[func_name](arguments...)
        @newbiesView[func_name](arguments...)
    @::[func_name] = delegate

root.CandidatesMainView.create_delegation 'calculate'

class root.PartyFilteredListView extends root.ListView
    options:
        autofetch: false

    initialize: ->
        super(arguments...)
        @unfilteredCollection = @.collection
        @unfilteredCollection.fetch()
        @setCollection new @unfilteredCollection.constructor undefined,
            comparator: (candidate) ->
                return -candidate.get 'score'
        root.global_events.on 'change_party', @partyChange

    filterByParty: (party) ->
        @unfilteredCollection.where party_name: party.get('name')

    partyChange: (party) =>
        @collection.reset @filterByParty party

class root.CandidateListView extends root.PartyFilteredListView
    options:
        itemView: root.CandidateView

    partyChange: (party) =>
        super(party)
        @collection.fetchAgendas()

    calculate: (weights) ->
        if not @collection.agendas_fetching
            throw "Agenda data not present yet"
        @collection.agendas_fetching.done =>
            @calculate_inner(weights)
            @collection.sort()

    calculate_inner: (weights) ->
        abs_sum = (arr) ->
            do_sum = (memo, item) ->
                memo += Math.abs item
            _.reduce(arr, do_sum, 0)
        weight_sum = abs_sum(weights)

        console.log "Weights: ", weights, weight_sum
        @collection.each (candidate) =>
            #console.log "calc: ", candidate, candidate.get('name')
            candidate.set 'score', _.reduce candidate.getAgendas(), (memo, score, id) ->
                #console.log "agenda: ", (weights[id] or 0), score, weight_sum, (weights[id] or 0) * score / weight_sum
                memo += (weights[id] or 0) * score / weight_sum
            , 0

class root.AgendaListView extends root.ListView
    el: '.agendas'
    options:
        collection: new root.AgendaList

        itemView: class extends root.ListViewItem
            className : "agenda_item"
            render : ->
                super()
                @.$('.slider').agendaSlider
                    min : -100
                    max : 100
                    value : @model.get "uservalue"
                    stop : @onStop
                @
            onStop : (event, ui) =>
                @model.set
                    uservalue : ui.value
            get_template: ->
                $("#agenda_template").html()

    showMarkersForCandidate: (candidate_model) ->
        candidate_agendas = candidate_model.getAgendas()
        @collection.each (agenda, index) ->
            value = candidate_agendas[agenda.id] or 0
            value = 50 + value / 2
            @.$(".slider").eq(index).agendaSlider "setCandidateMarker", value

class root.RecommendationsView extends root.PartyFilteredListView
    el: '.recommendations'
    options:
        itemView: class extends root.ListViewItem
            catchEvents: =>
                console.log 'change', @, arguments
                status = Boolean(@$el.find(':checkbox:checked').length)
                @model.set('status', status)
            events:
                'change': 'catchEvents'
            get_template: ->
                $("#recommendation_template").html()
    initialize: ->
        super(arguments...)
        @collection.on 'change', @applyChange, @

    applyChange: (recommendation) ->
        changeModelFunc = (candidates, attribute) ->
            (model_id, status) ->
                model = candidates.get(model_id)
                list = _.clone model.get attribute
                if recommendation.get('status')
                    list[recommendation.id] = true
                else
                    delete list[recommendation.id]
                model.set attribute, list
        _.each recommendation.get('positive_list')['members'], changeModelFunc(@options.members, 'recommendation_positive')
        _.each recommendation.get('negative_list')['members'], changeModelFunc(@options.members, 'recommendation_negative')
        _.each recommendation.get('positive_list')['newbies'], changeModelFunc(@options.newbies, 'recommendation_positive')
        _.each recommendation.get('negative_list')['newbies'], changeModelFunc(@options.newbies, 'recommendation_negative')

class root.AppView extends Backbone.View
    el: '#app_root'
    initialize: =>
        @partyListView = new root.DropdownContainer
            el: '.parties'
            collection: new root.PartyList
        @partyListView.on 'change', (model) =>
            console.log "Changed: ", this, arguments
            root.global_events.trigger 'change_party', model

        @districtListView = new root.DropdownContainer
            el: '.districts'
            collection: new Backbone.Collection
            autofetch: false
        root.global_events.on 'change_party', (party) =>
            # Assume members are already fetched - TODO - fix
            districts_names = _.chain(_.union(
                    @members.where party_name: party.get('name'),
                    @newbies.where party_name: party.get('name')
                )).pluck('attributes').pluck('district').uniq().value()
            districts = []
            for district in districts_names
                if not district
                    continue
                districts.push
                    id: district
                    name: district

            @districtListView.collection.reset districts

        @agendaListView = new root.AgendaListView

        @agendaListView.collection.on 'change', =>
            console.log "Model changed", arguments
            if @recalc_timeout
                clearTimeout @recalc_timeout
            recalc_timeout = setTimeout =>
                @recalc_timeout = null
                @calculate()
            , 100

        @members = new root.MemberList
        @newbies = new root.NewbiesList
        @candidatesView = new root.CandidatesMainView
            members: @members
            newbies: @newbies

        @candidatesView.on 'click', (candidate) =>
            @agendaListView.showMarkersForCandidate candidate
        @recommendations = new root.RecommendationList
        @recommendationsView = new root.RecommendationsView
            collection: @recommendations
            members: @members
            newbies: @newbies

    calculate: ->
        weights = {}
        @agendaListView.collection.each (agenda) =>
            uservalue = agenda.get("uservalue")
            weights[agenda.id] = uservalue
        @candidatesView.calculate(weights)


############### INIT ##############

$ ->
    root.global_events = _.extend({}, Backbone.Events)
    root.appView = new root.AppView
    return
