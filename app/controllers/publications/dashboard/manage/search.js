import Ember from 'ember';

export default Ember.Controller.extend({
    publication_id:null,
    application:Ember.inject.controller(),
    manageController: Ember.inject.controller("publications.dashboard.manage"),
});
