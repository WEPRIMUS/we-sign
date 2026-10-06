# frozen_string_literal: true

# WE Sign draws its icons with Phosphor (Regular) from lib/icons/mapping.json; lib/icons/generate.mjs writes them.
# These checks fail when an upstream merge brings a Tabler icon back where the mapping has a Phosphor one, or adds an
# icon the mapping does not know yet: add it to the mapping and run the generator again.
RSpec.describe 'WE Sign icons' do # rubocop:disable RSpec/DescribeClass
  let(:mapping) { JSON.parse(Rails.root.join('lib/icons/mapping.json').read) }
  let(:adapter) { Rails.root.join('app/javascript/icons/index.js').read }
  let(:sources) do
    Rails.root.glob('app/javascript/**/*.{js,vue}').reject { |f| f.to_s.include?('/app/javascript/icons/') }
         .index_with { |f| File.read(f) }
  end

  def kebab(component)
    component.delete_prefix('Icon').gsub(/([a-z])([A-Z0-9])/, '\1-\2').gsub(/([0-9])([A-Z])/, '\1-\2').downcase
  end

  it 'resolves @tabler/icons-vue to the Phosphor adapter in webpack' do
    config = Rails.root.join('config/webpack/webpack.config.js').read

    expect(config).to include("'@tabler/icons-vue$': require.resolve('../../app/javascript/icons/index.js')")
  end

  it 'has every Vue icon in the adapter, drawn by Phosphor unless the mapping keeps it' do
    imported = sources.values.flat_map do |src|
      src.scan(%r{import\s*\{([^\}]*)\}\s*from\s*'@tabler/icons-vue'}).flatten.flat_map { |list| list.split(',') }
    end.map(&:strip).uniq.reject(&:empty?)

    missing = imported.reject do |component|
      name = kebab(component)
      if mapping['keep'].key?(name)
        adapter.include?("export { default as #{component} } from '@tabler/icons-vue/dist/esm/icons/#{component}.js'")
      else
        mapping['map'].key?(name) && adapter.include?("export const #{component} = /* @__PURE__ */ icon('#{name}', '")
      end
    end

    expect(imported.size).to be > 100
    expect(missing).to be_empty, "not in lib/icons/mapping.json or not generated: #{missing.join(', ')}"
  end

  it 'imports Tabler icons only through the adapter' do
    deep = sources.select { |_, src| src.include?('@tabler/icons-vue/') || src.include?("'@tabler/icons'") }.keys

    expect(deep).to be_empty, "Tabler imported directly in #{deep.join(', ')}"
  end

  it 'draws every Rails icon partial with Phosphor unless the mapping keeps it' do
    partials = Rails.root.glob('app/views/icons/_*.html.erb')

    wrong = partials.reject do |file|
      name = File.basename(file, '.html.erb').delete_prefix('_').tr('_', '-')
      next true if mapping['keep'].key?(name)

      body = File.read(file)
      mapping['map'].key?(name) && body.include?('viewBox="0 0 256 256"') && body.include?('class="ph-icon ') &&
        body.exclude?('stroke=')
    end

    expect(partials.size).to be > 140
    expect(wrong.map { |f| File.basename(f) }).to be_empty
  end
end
