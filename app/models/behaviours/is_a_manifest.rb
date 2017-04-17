module IsAManifest
  # swith to use let Munki sort items or
  # let Munki server sort out the list of items to
  # install/uninstall/managed_update/optional install
  USING_PRECEDENT_ITEMS = true

  def self.included(base)
    base.extend ClassMethods

    base.class_eval do
      validates :name, :presence => true, :unique_as_shortname => true
      validates :shortname, :presence => true, :format => { :with => /^[a-z0-9-]+$/ }

      # Bundles
      has_many :bundle_items, :as => :manifest, :dependent => :destroy
      has_many :bundles, :through => :bundle_items, :dependent => :destroy

      # Install and uninstall items
      has_many :install_items, :as => :manifest, :dependent => :destroy
      has_many :uninstall_items, :as => :manifest, :dependent => :destroy

      # Managed Updates items
      has_many :managed_update_items, :as => :manifest, :dependent => :destroy

      # Optional Install items
      has_many :optional_install_items, :as => :manifest, :dependent => :destroy

      scope :eager_items, includes(item_includes)
    end
  end

  module ClassMethods
    # Return the default record
    # Requires a unit to be passed
    def default(unit)
      r = self.unit(unit).find_by_name("Default")
      r ||= self.unit(unit).find_by_name("default")
      r ||= self.unit(unit).first
    end

    # Attempts a couple different queries in order of importance to
    # find the appropriate record for the show action
    def find_for_show(unit, s)
      # Find by ID, if s is only digits
      current_unit = Unit.where(:shortname => unit).first unless unit.nil?
      record = where(:id => s).first if s =~ /^\d+$/
      # Find by id-name
      match = s.match(/^(\d+)([-_]{1})(.+)$/)
      if record.nil? && match.class == MatchData
        id = match[1]
        shortname = match[3]
        record ||= where(:id => id, :shortname => shortname).first
      end
      # Find by name
      record ||= where(:unit_id => current_unit.id, :shortname => s).first unless current_unit.nil?
      # Return results
      record
    end
    alias :find_for_show_super :find_for_show

    # Default parameters for a tabled_asm_select method
    # Takes an object of the current class and returns params
    def tas_params(model_obj, environment_id = nil)
      # Get all the package branches associated with this unit and environment
      # exam_packages = Package.unit_member(model_obj)
      environment_id ||= model_obj.environment_id
      environment = Environment.where(:id => environment_id).first
      environment ||= Environment.start

      pkg_branch_options = PackageBranch.unit(model_obj.unit).environment(environment).collect { |e| [e.name, e.id] }.sort { |a, b| a[0] <=> b[0] }

      bundle_options = if model_obj.class == Bundle
        Bundle.where("id <> ?", model_obj.id).unit(model_obj.unit).environment(environment).collect { |e| [e.name, e.id] }
                       else
        Bundle.unit(model_obj.unit).environment(environment).collect { |e| [e.name, e.id] }
                       end
      bundle_options.sort! { |a, b| a[0] <=> b[0] }

      model_name = to_s.underscore

      # Array for table_asm_select
      [{ :title => "Bundles",
         :model_name => model_name,
         :attribute_name => "bundle_ids",
         :select_title => "Select a bundle",
         :options => bundle_options,
         :selected_options => model_obj.bundle_ids },
       { :title => "Installs",
         :model_name => model_name,
         :attribute_name => "installs_package_branch_ids",
         :select_title => "Select a package branch",
         :options => pkg_branch_options,
         :selected_options => model_obj.installs_package_branch_ids },
       { :title => "Uninstalls",
         :model_name => model_name,
         :attribute_name => "uninstalls_package_branch_ids",
         :select_title => "Select a package branch",
         :options => pkg_branch_options,
         :selected_options => model_obj.uninstalls_package_branch_ids },
       { :title => "Managed Update",
         :model_name => model_name,
         :attribute_name => "updates_package_branch_ids",
         :select_title => "Select a managed update",
         :options => pkg_branch_options,
         :selected_options => model_obj.updates_package_branch_ids },
       { :title => "Optional Install",
         :model_name => model_name,
         :attribute_name => "optional_installs_package_branch_ids",
         :select_title => "Select optional intalls",
         :options => pkg_branch_options,
         :selected_options => model_obj.optional_installs_package_branch_ids }]
    end

    def item_associations
      [:package, { :package_branch => [{ :packages => [:package_branch, :unit] }, :version_tracker, :package_category] }, :manifest]
    end

    # Array of associations to load for associates items
    def item_includes
      [
        { :install_items => item_associations },
        { :uninstall_items => item_associations },
        { :managed_update_items => item_associations },
        { :optional_install_items => item_associations },
        :bundles,
        :unit
      ]
    end

    def bundle_includes
      [{ :bundles => item_includes }, { :bundle_items => :bundle }]
    end
  end

  # Takes a name attribute and returns a valid shortname attribute
  def conform_name_to_shortname(name = nil)
    name ||= self.name
    name.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
  end

  # Overwrite the default name setter to add shortname attribute when creating a name
  def name=(value)
    self.shortname = conform_name_to_shortname(value)
    write_attribute(:name, value)
  end

  # Return all the environments visible to this object
  def environments
    environment.environments
  end

  # Recursively collect, based on precedent, the install
  # items.
  def precedent_install_items
    exclusion_items_hash = create_item_hash(uninstall_items)
    precedent_items("install_items", exclusion_items_hash)
  end

  def precedent_uninstall_items
    exclusion_items_hash = create_item_hash(install_items)
    precedent_items("uninstall_items", exclusion_items_hash)
  end

  def precedent_managed_update_items
    exclusion_items_hash = create_item_hash(precedent_install_items).merge(create_item_hash(precedent_uninstall_items))
    precedent_items("managed_update_items", exclusion_items_hash)
  end

  def precedent_optional_install_items
    exclusion_items_hash = create_item_hash(precedent_install_items).merge(create_item_hash(precedent_uninstall_items))
    precedent_items("optional_install_items", exclusion_items_hash)
  end

  def precedent_items(item_name, exclusion_items_hash)
    item_hash = create_item_hash(send(item_name))
    second_item_hash = create_item_hash(bundles.map { |b| b.send("precedent_#{item_name}") }.flatten)
    (third_item_hash = is_a?(Computer)) && computer_group.present? ? create_item_hash(computer_group.send("precedent_#{item_name}")) : {}

    aux_items = third_item_hash.merge(second_item_hash)
    aux_items.delete_if { |k, v| exclusion_items_hash[k].present? }
    aux_items.merge(item_hash).values
  end

  # Takes an array of InstallItem/UninstallItem/OptionalInstallItem
  # instances and returns a hash with keys matching the associated
  # package branch ID.
  def create_item_hash(items)
    hash = {}
    items.each do |items|
      hash[items.package_branch.id] = items
    end
    hash
  end

  # Takes option to whether use the presedent_items or
  # let Munki to sort out the install/uninstall/optional install conflict
  def create_item_array(item_method, using_precedent_items = true)
    item_array = []
    method = if using_precedent_items
      "precedent_#{item_method}"
             else
      item_method.to_s
             end

    send(method.to_s).each do |item|
      item_array << if item.package_id.blank?
        item.package.to_s
                    else
        item.package.to_s(:version)
                    end
    end
    item_array
  end

  # Returns an array of strings representing managed_installs
  # based on the items specified in install_items
  def managed_installs
    USING_PRECEDENT_ITEMS ? create_item_array("install_items") : create_item_array("install_items", false)
  end

  # Concatentates installs (specified by admins) and user installs (specified
  # by users) to create the managed_installs virtual attribute
  def managed_uninstalls
    USING_PRECEDENT_ITEMS ? create_item_array("uninstall_items") : create_item_array("uninstall_items", false)
  end

  # Same as managed_installs and managed_uninstalls
  # managed_updates virtual attribute update items only if already installed
  def managed_updates
    USING_PRECEDENT_ITEMS ? create_item_array("managed_update_items") : create_item_array("managed_update_items", false)
  end

  # Same as managed_installs and managed_uninstalls
  # optional_installs virtual attribute let user to choose a list of items to install
  def managed_optional_installs
    USING_PRECEDENT_ITEMS ? create_item_array("optional_install_items") : create_item_array("optional_install_items", false)
  end

  # Pass a package object or package ID to append the package to this record
  # If the package's package branch, or another version of the package is specified
  # this package replaces the old
  def append_package_install(package)
    begin
      # Try to find the package, unless we have a package instance
      package = Package.find(package) unless package.class == Package
    rescue
      raise ComputerException, "Malformed argument passed to append_package_install method"
    end
    its = install_items
    # Remove install items referring to the same package branch as "package"
    its = its.map do |it|
      it unless it.package_branch.id == package.package_branch.id
    end
    its = its.compact
    its << install_items.build({ :package_id => package.id, :package_branch_id => package.package_branch.id })
    self.install_items = its
  end

  # Add package objects or IDs using append_package_installs
  # TO-DO Could be improved by rewrite, as it simply calls another,
  # more expensive method
  def append_package_installs(packages)
    packages.map { |package| append_package_branch_install(package) }
  end

  # Pass a package branch object or package branch ID to append the
  # package branch to this record.  If the package's package branch,
  # or another version of the package is specified this package
  # replaces the old
  def append_package_branch_install(pb)
    begin
      # Try to find the package, unless we have a package instance
      pb = PackageBranch.find(pb) unless pb.class == PackageBranch
    rescue
      raise ComputerException, "Malformed argument passed to append_package_branch_install method"
    end
    its = install_items
    # Remove install items referring to the same package branch as "pb"
    its = its.map do |it|
      it unless it.package_branch.id == pb.id
    end
    its = its.compact
    its << install_items.build({ :package_branch_id => pb.id })
    self.install_items = its
  end

  # Add package branch items using append_package_branch_installs
  # TO-DO Could be improved by rewrite, as it simply calls another,
  # more expensive method
  def append_package_branch_installs(pbs)
    pbs.map { |pb| append_package_branch_install(pb) }
  end

  # Pass a list of Package records or package IDs and install_item associations will be built
  def package_installs=(packages)
    package_objects = []
    packages.each do |package|
      if package.class == Package
        package_objects << package
      else
        p = Package.where(:id => package.to_i).limit(1).first
        package_objects << p unless p.nil?
      end
    end
    self.installs = package_objects
  end

  # Pass a list of Package records or package IDs and install_item associations will be built
  def package_branch_installs=(package_branches)
    pb_objects = []
    pbs.each do |package_branch|
      if package_branch.class == PackageBranch
        pb_objects << package_branch
      else
        pb = PackageBranch.where(:id => package_branch.to_i).limit(1).first
        pbs_objects << p unless p.nil?
      end
    end
    self.installs = pb_objects
  end

  # Assign the list of items to a specific association (assoc)
  def build_package_association_assignment(assoc, list)
    # Blank out the association
    send("#{assoc}=", [])
    unless list.nil?
      list.each do |item|
        # Create association for...
        if item.class == Package
          # ...a specific package
          send(assoc.to_s).build({ :package_id => item.id, :package_branch_id => item.package_branch.id })
        elsif item.class == PackageBranch
          # ...the latest package from a package branch
          send(assoc.to_s).build({ :package_branch_id => item.id })
        end
      end
    end
  end

  # Gets the packages that belong to this manifests installs virtual attribute
  def installs
    install_items.collect(&:package)
  end

  # Pass a list of Package or PackageBranch records and install_item associations will be built
  def installs=(list)
    build_package_association_assignment(:install_items, list)
  end

  def installs_package_branch_ids
    install_items.collect(&:package_branch).uniq.collect(&:id)
  end

  # Gets the packages that belong to this manifests uninstalls virtual attribute
  def uninstalls
    uninstall_items.collect(&:package)
  end

  def uninstalls=(list)
    build_package_association_assignment(:uninstall_items, list)
  end

  def uninstalls_package_branch_ids
    uninstall_items.collect(&:package_branch).uniq.collect(&:id)
  end

  # Gets the packages that belong to this manifests user_installs virtual attribute
  def user_installs
    user_install_items.collect(&:package)
  end

  # Pass a list of Package or PackageBranch records and install_item associations will be built
  def user_installs=(list)
    build_package_association_assignment(:user_install_items, list)
  end

  def user_installs_package_branch_ids
    user_install_items.collect(&:package_branch).uniq.collect(&:id)
  end

  # Gets the packages that belong to this manifests user_uninstalls virtual attribute
  def user_uninstalls
    user_uninstall_items.collect(&:package)
  end

  # Pass a list of Package or PackageBranch records and install_item associations will be built
  def user_uninstalls=(list)
    build_package_association_assignment(:user_uninstall_items, list)
  end

  def user_uninstalls_package_branch_ids
    user_uninstall_items.collect(&:package_branch).uniq.collect(&:id)
  end

  # Gets the packages that belong to this manifests managed_update virtual attribute
  def updates
    managed_update_items.collect(&:package)
  end

  # Pass a list of Package or PackageBranch records and managed_update_items associations will be built
  def updates=(list)
    build_package_association_assignment(:managed_update_items, list)
  end

  def updates_package_branch_ids
    managed_update_items.collect(&:package_branch).uniq.collect(&:id)
  end

 # Gets the packages that belong to this manifests optional_installs virtual attribute
  def optional_installs
    optional_install_items.collect(&:package)
  end

  # Pass a list of Package or PackageBranch records and optional_install_items associations will be built
  def optional_installs=(list)
    build_package_association_assignment(:optional_install_items, list)
  end

  def optional_installs_package_branch_ids
    optional_install_items.collect(&:package_branch).uniq.collect(&:id)
  end

  def bundle_ids
    bundles.map(&:id)
  end

  def bundle_ids=(value)
    Bundle.where(:id => value).to_a
  end

  def bundle_ids
    bundles.map(&:id)
  end

  def bundle_ids=(value)
    self.bundles = Bundle.where(:id => value).to_a
  end

  def installs_package_branch_ids
    install_items.map(&:package_branch).map(&:id)
  end

  def installs_package_branch_ids=(value)
    self.installs = PackageBranch.where(:id => value).to_a
  end

  def uninstalls_package_branch_ids
    uninstall_items.map(&:package_branch).map(&:id)
  end

  def uninstalls_package_branch_ids=(value)
    self.uninstalls = PackageBranch.where(:id => value).to_a
  end

  def updates_package_branch_ids
    managed_update_items.map(&:package_branch).map(&:id)
  end

  def updates_package_branch_ids=(value)
    self.updates = PackageBranch.where(:id => value).to_a
  end

  def optional_installs_package_branch_ids
    optional_install_items.map(&:package_branch).map(&:id)
  end

  def optional_installs_package_branch_ids=(value)
    self.optional_installs = PackageBranch.where(:id => value).to_a
  end

  # Returns all package_branches that belongs to the unit and the environment
  def assignable_package_branches
    # Grab all package branches referenced by packages of this unit and environment
    # TO-DO use include to minimize db queries made for package_branches
    packages = Package.unit(unit).environments(environments)
    package_branches = packages.collect(&:package_branch)

    # Remove duplicate package branches from the list of package branches
    uniq_pb_ids = []
    uniq_pbs = []
    package_branches.each do |pb|
      unless uniq_pb_ids.include?(pb.id)
        uniq_pbs << pb
        uniq_pb_ids << pb.id
      end
    end

    uniq_pbs
  end

  # add the path to the plist, called by included_manifests
  def to_s(format = nil)
    case format
      when :unique then "#{id}_#{name}"
      when :path then "#{Unit.where(:id => unit_id).first.name}/#{self.class.to_s.pluralize.tableize}/#{to_s(:unique)}"
      else name
    end
  end

  # Create a hash intended for plist output
  # Won't include the entire object attributes
  # but only the ones relevant for munki clients
  def serialize_for_plist
    h = {}
    h[:name] = name
    h[:included_manifests] = included_manifests unless USING_PRECEDENT_ITEMS
    h[:managed_installs] = managed_installs
    h[:managed_uninstalls] = managed_uninstalls
    h[:managed_updates] = managed_updates
    h[:optional_installs] = managed_optional_installs
    h
  end

  alias :serialize_for_plist_super :serialize_for_plist

  # Converts serialized object into plist string
  def to_plist
    plist = serialize_for_plist.to_plist
    # Fix ^M encoding CR issue
    plist.gsub(/\r\n?/, "\n")
  end

  def included_manifests
    a = bundles.collect { |e| "#{e.to_s(:path)}.plist" }
    if respond_to?(:computer_group)
      a << "#{computer_group.to_s(:path)}.plist" unless computer_group.nil?
    end
    a
  end

  # Default parameters for the table_asm_select method
  # Returns values for self
  def tas_params(environment_id = nil)
    self.class.tas_params(self, environment_id)
  end

  # overwrite default to_param for friendly bundle URLs
  def to_param
    shortname
  end
end
