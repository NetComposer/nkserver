# NkSERVER

# Introduction

NkSERVER is an Erlang framework to develop microservices based on powerful plugin mechanism. A growing number of _Packages_ following this pattern are available, like Rest servers, Kafka producers and consumers, database connectors, etc. [NkSIP](https://github.com/NetComposer/nksip) is also based on NKSERVER.

## Characteristics

* Any Erlang application can start any number of _services_, inserting them in its OTP application supervisor.
* A powerful plugin mechanism, so that any package is made of a set of _plugins_ and some custom login.
* Configuration for services can be changed at any moment.
* Designed from scratch to be highly scalable, having a very low latency.
* Rich set of Packages already available to build servers.


## Packages and plugins

NkSERVER features a sophisticated package system, based on plugins that allows a developer to modify the behavior of packages without having to modify its core, while having nearly zero overhead. Each plugin adds new _APIs_ and _callbacks_ or _hooks_, available to the service developer or other, higher level plugins.

Each server using NKSERVICE defines a _callback module_ and a base _package_, and optionally, a set of plugins.

Plugins have the concept _hierarchy_ and _dependency_. For example, if _pluginA_ implements callback _callback1_, we can define a new plugin _pluginB_ which depends on _pluginA_ and also implements _callback1_. Now, if the service (or other higher level plugin) happens to use this _callback1_, when it is called by NkSERVER, the one that will be called first will ve the _pluginB_ version, and only if it returns `continue` or `{continue, Updated}` the version of `pluginA` would be called.

Any plugin can have any number of dependent plugins. NkSERVER will ensure that versions of plugin callbacks on higher order plugins are called first, calling the next only in case it passes the call to the next plugin, possibly modifying the request. Eventually, the call will reach the default NkSERVER's implementation of the callback (defined in [nkserver_callbacks.erl](src/nkserver_callbacks.erl) if all defined callbacks decide to continue, or no plugin has implemented this callback).

Plugin callbacks must be implemented in a module with the same name as the plugin plus _"_callbacks"_ (for example `my_plugin_callbacks.erl`). Plugin definitions must be implemented in a module with the same name of the plugin, plus _"_plugin"_

This callback chain behavior is implemented in Erlang and **compiled on the fly**, into a run-time generated service callback module. This way, any call to any plugin callback function is really fast, very similar as if it were hard-coded from the beginning. Calls to plugin callbacks not implemented in any plugin go directly to the default NkSERVER implementation.

Each server can have **different set of plugins**, and it can **it be changed in real time** as any other server configuration value.

