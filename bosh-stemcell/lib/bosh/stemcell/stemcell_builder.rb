require 'fileutils'
require 'bosh/stemcell/stage_collection'

module Bosh::Stemcell
  class StemcellBuilder
    def initialize(dependencies = {})
      @gem_components = dependencies.fetch(:gem_components)
      @environment = dependencies.fetch(:environment)
      @runner = dependencies.fetch(:runner)
      @collection = dependencies.fetch(:collection)
    end

    def build
      gem_components.build_release_gems
      environment.prepare_build

      stemcell_stages = collection.extract_operating_system_stages +
        collection.agent_stages +
        collection.build_stemcell_image_stages
      runner.configure_and_apply(stemcell_stages)
    end

    private

    attr_reader :gem_components, :environment, :collection, :runner
  end
end
