shared_module('media-nextcloud', files('nextcloud_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'music' / 'nextcloud')
configure_file(input: 'nextcloud.plugin', output: 'nextcloud.plugin', copy: true)
install_data('nextcloud.plugin', install_dir: app_plugins_dir / 'music' / 'nextcloud')
