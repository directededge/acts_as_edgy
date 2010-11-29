acts_as_edgy
============

acts_as_edgy makes it really easy to add [Directed Edge](http://www.directededge.com/)
recommendations to a Rails app using your existing models and data.

Installing acts_as_edgy
-----------------------

You can install acts as edgy to your model with the following steps:

* Install the directed-edge and will_paginate gems:

      sudo gem install directed-edge will_paginate

  You may also wish to add these gems to your config/environment.rb
  
* Install the acts_as_edgy plugin in your Rails app:

      ./script/plugin install https://github.com/directededge/acts_as_edgy.git

Configuring acts_as_edgy
------------------------

You'll need a Directed Edge account.  ([Sign up here](http://www.directededge.com/signup.html))
Once you have your account info handy, you cat store it in an initializer by
running:

    rake edgy:configre

Adding acts_as_edgy to a model
------------------------------

The acts_as_edgy method associates data from one model to another target model via
connections between them in your current model hierarchy.  For example, with the
Rails e-commerce application [Spree](http://spreecommerce.com/), we want to
associate a users with products by their purchases.

To do that we add an acts_as_edgy statement to our User model with name for the
relationship type (i.e. "purchase") and the path between those models, which we
call "bridges".  Specifically, in Spree's database layout a purchase is
represented by:

* Order references a User ID and LineItem IDs
* LineItem references Variant IDs
* Variant IDs reference Product IDs

We tell acts_as_edgy about that thusly:

    class User < ActiveRecord::Base
      acts_as_edgy(:purchase, Order, LineItem, Variant, Product)
      # ...
    end

And acts_as_edgy figures out the rest, including which columns to reference
when building the path from User to Product.

If we envisoned something a litle simpler, for instance, a "like" for a product,
it'd just be:

    class User < ActiveRecord::Base
      acts_as_edgy(:like, Like, Product)
      # ...
    end

Basically you just have to tell acts_as_edgy how to get to from the model where
you're adding the line to the thing that you want to recommend.

Exporting data
--------------

Since acts_as_edgy now knows how your models are connected, it's time to push that
data over to Directed Edge's servers.  You can do that with a simple Rake call:

    rake edgy:export

By default, also, all relevant updates to your data that you make while the
application is running will be instantly pushed over to Directed Edge's servers,
however, it's not a bad idea to stick the above call in a cron job that runs
every week or so to make sure that things are perfectly in sync.

Accessing the recommendations
-----------------------------

acts_as_edgy adds a couple of methods to your models to make it easy to get at the
recommendations.  For instance, to access the related products for an item, you
can do:

    product = Product.first
    related = product.edgy_related

By default <tt>edgy_related</tt> returns items that come from the same model,
whereas <tt>edgy_recommended</tt> will recommend things from the target models
(i.e. the last model listed) in the acts_as_edgy lines that you add to your
models.  Specifically, for personalized recommendations for a user you can do:

    user = User.first
    recommended = user.edgy_recommended(:max_results => 4)
    shirts = user.edgy_recommended(:max_results => 4, :tags => [ 'shirt' ])

And so on.

Further information
-------------------

Feel free to [hit us up](mailto:info@directededge.com) or check out our
[developer wiki](http://developer.directededge.com/) for more info on our web
services API.

Copyright (c) 2010 Directed Edge, released under the MIT license
