shared_module('media-dlna', files('dlna_source.vala', 'register.vala'),
  dependencies: plugin_deps + [xml_dep],
  install: true, install_dir: app_plugins_dir / 'common' / 'dlna')
configure_file(input: 'dlna.plugin', output: 'dlna.plugin', copy: true)
install_data('dlna.plugin', install_dir: app_plugins_dir / 'common' / 'dlna')
