Gem::Specification.new do |s|
  s.platform = Gem::Platform::RUBY
  s.name = 'activerecord-redshift-adapter'
  s.version = '2.0.0'
  s.summary = 'Amazon Redshift adapter for ActiveRecord'
  s.description = 'Amazon Redshift adapter for ActiveRecord.'
  s.license = 'MIT'

  s.author = ['Nancy Foen', 'Minero Aoki', 'iamdbc', 'Quentin Rousseau', 'Johan Le Bray', 'Owen Stephens', 'rightsup']
  s.homepage = 'https://github.com/rightsup/activerecord-adapter-redshift'

  s.files = Dir.glob(['LICENSE', 'README.md', 'lib/**/*.rb'])
  s.require_path = 'lib'

  s.required_ruby_version = '>= 3.2'
  s.add_runtime_dependency 'activerecord', '>= 8.0', '< 9'
  s.add_runtime_dependency 'pg', '~> 1.0'
end
