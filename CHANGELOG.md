# Changelog

## [0.2.0](https://github.com/adrian729/ducktape.nvim/compare/v0.1.0...v0.2.0) (2026-10-15)


### Features

* **chat:** focus key &lt;leader&gt;cf and chat-window lifetime rules ([fd6763a](https://github.com/adrian729/ducktape.nvim/commit/fd6763ae207720c4633bf6bbcb6943c086603421))
* **opencode:** native tool-free relay, no external opencode-llm dependency ([d474637](https://github.com/adrian729/ducktape.nvim/commit/d47463758d3bf918193742bc45af19a4f5958059))


### Bug Fixes

* **chat:** leave the quit to nvim, keep the chat down when it is refused ([d54727c](https://github.com/adrian729/ducktape.nvim/commit/d54727c194b7967484f1d67c44f3ae1cd19ae208))
* **doc:** force LC_ALL=C for make doc ([45c14c5](https://github.com/adrian729/ducktape.nvim/commit/45c14c598b57048814171f02ea560865a4bdeac1))
* prevent duplicate help tags during installation ([63e4e9f](https://github.com/adrian729/ducktape.nvim/commit/63e4e9f40cbd3899e8234dac3a244ff5eead659d))
* **providers:** guard subprocess model discovery against a missing binary ([62ee92d](https://github.com/adrian729/ducktape.nvim/commit/62ee92d3e232fc7cebd8ec30d7c2bd4d2f517487))
* **test:** pin test_inline_list_edges to the ollama provider ([62ee92d](https://github.com/adrian729/ducktape.nvim/commit/62ee92d3e232fc7cebd8ec30d7c2bd4d2f517487))
