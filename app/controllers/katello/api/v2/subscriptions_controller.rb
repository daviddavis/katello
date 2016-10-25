module Katello
  class Api::V2::SubscriptionsController < Api::V2::ApiController
    include Katello::Concerns::FilteredAutoCompleteSearch

    before_action :find_activation_key
    before_action :find_host, :only => :index
    before_action :find_optional_organization, :only => [:index, :available, :show]
    before_action :find_organization, :only => [:upload, :delete_manifest,
                                                :refresh_manifest, :manifest_history]
    before_action :find_provider
    before_action :deprecated, :only => [:create, :destroy]

    skip_before_action :check_content_type, :only => [:upload]

    resource_description do
      description "Subscriptions management."
      api_version 'v2'
    end

    api :GET, "/organizations/:organization_id/subscriptions", N_("List organization subscriptions")
    api :GET, "/activation_keys/:activation_key_id/subscriptions", N_("List an activation key's subscriptions")
    api :GET, "/subscriptions"
    param_group :search, Api::V2::ApiController
    param :organization_id, :number, :desc => N_("Organization ID"), :required => true
    param :host_id, String, :desc => N_("id of a host"), :required => false
    param :activation_key_id, String, :desc => N_("Activation key ID"), :required => false
    param :available_for, String, :desc => N_("Object to show subscriptions available for, either 'host' or 'activation_key'"), :required => false
    param :match_host, :bool, :desc => N_("Ignore subscriptions that are unavailable to the specified host")
    param :match_installed, :bool, :desc => N_("Return subscriptions that match installed products of the specified host")
    param :no_overlap, :bool, :desc => N_("Return subscriptions which do not overlap with a currently-attached subscription")
    def index
      collection = scoped_search(
        index_relation.uniq, :cp_id, :asc, resource_class: Pool, includes: [:subscription])
      if params[:activation_key_id]
        key_pools = @activation_key.get_key_pools
        collection[:results] = collection[:results].map do |pool|
          ActivationKeySubscriptionsPresenter.new(pool, key_pools)
        end
      end
      respond(:collection => collection)
    end

    def index_relation
      return for_host if params[:host_id]
      return available_for_activation_key if params[:available_for] == "activation_key"
      collection = Pool.readable
      collection = collection.where(:unmapped_guest => false)
      collection = collection.get_for_organization(Organization.find(params[:organization_id])) if params[:organization_id]
      collection = collection.for_activation_key(@activation_key) if params[:activation_key_id]
      collection
    end

    api :GET, "/organizations/:organization_id/subscriptions/:id", N_("Show a subscription")
    api :GET, "/subscriptions/:id", N_("Show a subscription")
    param :organization_id, :number, :desc => N_("Organization identifier")
    param :id, :number, :desc => N_("Subscription identifier"), :required => true
    def show
      @resource = Katello::Pool.with_identifier(params[:id])
      respond(:resource => @resource)
    end

    api :POST, "/activation_keys/:activation_key_id/subscriptions", N_("Add a subscription to an activation key"), :deprecated => true
    param :id, String, :desc => N_("Subscription Pool uuid"), :required => false
    param :activation_key_id, String, :desc => N_("ID of the activation key"), :required => false
    param :quantity, :number, :desc => N_("Quantity of this subscriptions to add"), :required => false
    param :subscriptions, Array, :desc => N_("Array of subscriptions to add"), :required => false do
      param :id, String, :desc => N_("Subscription Pool uuid"), :required => true
      param :quantity, :number, :desc => N_("Quantity of this subscriptions to add"), :required => true
    end
    def create
      if params[:subscriptions]
        params[:subscriptions].each do |sub|
          subscription = Pool.find(sub[:id])
          @activation_key.subscribe(subscription.cp_id, subscription[:quantity])
        end
      elsif params[:id] && params.key?(:quantity)
        sub = subscription.find(params[:id])
        @activation_key.subscribe(sub.cp_id, params[:quantity])
      end

      subscriptions = index_activation_key
      respond_for_index(:collection => subscriptions, :template => 'index')
    end

    api :DELETE, "/activation_keys/:activation_key_id/subscriptions/:id", N_("Unattach a subscription"), :deprecated => true
    param :id, String, :desc => N_("Subscription ID"), :required => false
    param :activation_key_id, String, :desc => N_("activation key ID")
    def destroy
      @activation_key.unsubscribe(params[:id])
      respond_for_index(:collection => scoped_search(import_subscriptions.uniq, :cp_id, :asc, :resource_class => Pool), :template => "index")
    end

    api :POST, "/organizations/:organization_id/subscriptions/upload", N_("Upload a subscription manifest")
    param :organization_id, :number, :desc => N_("Organization id"), :required => true
    param :content, File, :desc => N_("Subscription manifest file"), :required => true
    param :repository_url, String, :desc => N_("repository url"), :required => false
    def upload
      fail HttpErrors::BadRequest, _("No manifest file uploaded") if params[:content].blank?

      begin
        # candlepin requires that the file has a zip file extension
        temp_file = File.new(File.join("#{Rails.root}/tmp", "import_#{SecureRandom.hex(10)}.zip"), 'wb+', 0600)
        temp_file.write params[:content].read
      ensure
        temp_file.close
      end

      # repository url
      if (repo_url = params[:repository_url])
        @provider.repository_url = repo_url
        @provider.save!
      end

      task = async_task(::Actions::Katello::Organization::ManifestImport, @organization, File.expand_path(temp_file.path), params[:force])
      respond_for_async :resource => task
    end

    api :PUT, "/organizations/:organization_id/subscriptions/refresh_manifest", N_("Refresh previously imported manifest for Red Hat provider")
    param :organization_id, :number, :desc => N_("Organization id"), :required => true
    def refresh_manifest
      task = async_task(::Actions::Katello::Organization::ManifestRefresh, @organization)
      respond_for_async :resource => task
    end

    api :POST, "/organizations/:organization_id/subscriptions/delete_manifest", N_("Delete manifest from Red Hat provider")
    param :organization_id, :number, :desc => N_("Organization id"), :required => true
    def delete_manifest
      task = async_task(::Actions::Katello::Organization::ManifestDelete, @organization)
      respond_for_async :resource => task
    end

    api :GET, "/organizations/:organization_id/subscriptions/manifest_history", N_("obtain manifest history for subscriptions")
    param :organization_id, :number, :desc => N_("Organization ID"), :required => true
    def manifest_history
      @manifest_history = @organization.manifest_history
      respond_with_template_collection(params[:action], "subscriptions", collection: @manifest_history)
    end

    def for_host
      match_attached = params[:available_for] != "host"
      params[:match_host] = ::Foreman::Cast.to_bool(params[:match_host]) if params[:match_host]
      params[:match_installed] = ::Foreman::Cast.to_bool(params[:match_installed]) if params[:match_installed]
      params[:no_overlap] = ::Foreman::Cast.to_bool(params[:no_overlap]) if params[:no_overlap]

      @host.subscription_facet.candlepin_consumer.filtered_pools(match_attached, params[:match_host], params[:match_installed], params[:no_overlap])
    end

    protected

    def find_host
      find_host_with_subscriptions(params[:host_id], :view_hosts) if params[:host_id]
    end

    def find_activation_key
      @activation_key = ActivationKey.find_by!(:id => params[:activation_key_id]) if params[:activation_key_id]
    end

    def find_provider
      @organization = @activation_key.organization if @activation_key
      @organization = @subscription.organization if @subscription
      @provider = @organization.redhat_provider if @organization
    end

    private

    def resource_class
      Pool
    end

    def default_sort
      %w(id desc)
    end

    def import_subscriptions
      subscriptions = if @activation_key
                        index_activation_key
                      else
                        index_organization
                      end
      cp_ids = subscriptions.collect { |x| x["id"] }
      index_relation.where("cp_id not in (?)", cp_ids)
    end

    def index_activation_key
      @activation_key.subscriptions
    end

    def index_organization
      @organization.subscriptions
    end

    def available_for_activation_key
      @activation_key.available_subscriptions
    end

    def deprecated
      ::Foreman::Deprecation.api_deprecation_warning("it will be removed in Katello 2.6, Please see /api/v2/activation_keys/:id/add_subscriptions and \
          /api/v2/activation_keys/:id/remove_subscriptions")
    end
  end
end
