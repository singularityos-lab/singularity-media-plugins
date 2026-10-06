if webkit_dep.found()
  shared_module('videos-test-embed', files('test_embed_source.vala'),
    dependencies: video_deps, vala_args: video_args)
  configure_file(input: 'test-embed.plugin', output: 'test-embed.plugin', copy: true)
endif
