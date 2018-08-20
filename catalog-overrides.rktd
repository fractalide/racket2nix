#hash(("grip"
        .
        #hasheq((build
                 .
                 #hash((docs . (("main" "grip" "doc/grip@grip/index.html")))
                       (min-failure-log . #f)
                       (conflicts-log . #f)
                       (dep-failure-log . #f)
                       (success-log . "server/built/install/grip.txt")
                       (test-success-log
                        .
                        "server/built/test-success/grip.txt")
                       (failure-log . #f)
                       (test-failure-log . #f)))
                (last-checked . 1522414406)
                (conflicts . ())
                (dependencies
                 .
                 ("base"
                  "typed-racket-lib"
                  "typed-racket-more"
                  "r6rs-lib"
                  "srfi-lite-lib"
                  "racket-doc"
                  "typed-racket-doc"
                  "scribble-lib"
                  "typed-racket-more"))
                (authors . ("ray.racine@gmail.com"))
                (last-edit . 1502542200)
                (description
                 .
                 "A sparse prelude-lite level library of common things targeting Typed Racket.")
                (implies . ())
                (modules
                 .
                 ((lib "grip/data/datetime/format-util.rkt")
                  (lib "grip/data/datetime/const.rkt")
                  (lib "grip/data/prelude.rkt")
                  (lib "grip/data/datetime/instant.rkt")
                  (lib "grip/data/list.rkt")
                  (lib "grip/scribblings/control/conditionals.scrbl")
                  (lib "grip/data/datetime.rkt")
                  (lib "grip/data/format.rkt")
                  (lib "grip/r6rslib/enums.rkt")
                  (lib "grip/scribblings/control/manual.scrbl")
                  (lib "grip/control/test/when-let-test.rkt")
                  (lib "grip/data/datetime/parse.rkt")
                  (lib "grip/r6rslib/io/private/ports-typed.rkt")
                  (lib "grip/concurrent/multicast.rkt")
                  (lib "grip/data/string.rkt")
                  (lib "grip/control/conditional-let.rkt")
                  (lib "grip/control/test/awhen-test.rkt")
                  (lib "grip/scribblings/system/manual.scrbl")
                  (lib "grip/data/datetime/types.rkt")
                  (lib "grip/system/interface.rkt")
                  (lib "grip/data/datetime/convert.rkt")
                  (lib "grip/scribblings/system/filepath.scrbl")
                  (lib "grip/control/test/cond-let-test.rkt")
                  (lib "grip/control/test/if-let-test.rkt")
                  (lib "grip/control/conditional-anaphoric.rkt")
                  (lib "grip/data/symbol.rkt")
                  (lib "grip/scribblings/concurrent/multicast.scrbl")
                  (lib "grip/scribblings/grip.scrbl")
                  (lib "grip/data/either.rkt")
                  (lib "grip/data/hash.rkt")
                  (lib "grip/control/test/acond-test.rkt")
                  (lib "grip/data/date.rkt")
                  (lib "grip/data/datetime/date.rkt")
                  (lib "grip/data/datetime/leapsecond.rkt")
                  (lib "grip/r6rslib/arithmetic/bitwise.rkt")
                  (lib "grip/data/util.rkt")
                  (lib "grip/data/partialfn.rkt")
                  (lib "grip/data/try.rkt")
                  (lib "grip/control/test/aif-test.rkt")
                  (lib "grip/scribblings/concurrent/manual.scrbl")
                  (lib "grip/data/opt.rkt")
                  (lib "grip/r6rslib/bytevectors.rkt")
                  (lib "grip/data/struct.rkt")
                  (lib "grip/data/text.rkt")
                  (lib "grip/scribblings/system/interface.scrbl")
                  (lib "grip/system/filepath.rkt")
                  (lib "grip/r6rslib/io/ports.rkt")
                  (lib "grip/data/datetime/format.rkt")))
                (versions
                 .
                 #hash(("0.2.1"
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/grip/tree/master")
                                (checksum
                                 .
                                 "bb127ff3bd2eef2f4b1a3690d946fe79ae9558ce")
                                (source . "https://gitlab.com/RayRacine/grip.git")))
                       (default
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/grip/tree/master")
                                (checksum
                                 .
                                 "bb127ff3bd2eef2f4b1a3690d946fe79ae9558ce")
                                (source
                                 .
                                 "https://gitlab.com/RayRacine/grip.git")))))
                (search-terms
                 .
                 #hasheq((control . #t)
                         (:build-success: . #t)
                         (data . #t)
                         (iteratee . #t)
                         (:docs: . #t)
                         (ring:1 . #t)
                         (author:ray.racine@gmail.com . #t)))
                (name . "grip")
                (checksum . "bb127ff3bd2eef2f4b1a3690d946fe79ae9558ce")
                (last-updated . 1502816092)
                (source . "https://gitlab.com/RayRacine/grip.git")
                (tags . ("control" "data" "iteratee"))
                (author . "ray.racine@gmail.com")
                (checksum-error . #f)
                (ring . 1)))
       ("pipe"
        .
        #hasheq((build
                 .
                 #hash((docs . (("main" "pipe" "doc/pipe@pipe/index.html")))
                       (min-failure-log . #f)
                       (conflicts-log . #f)
                       (dep-failure-log . #f)
                       (success-log . "server/built/install/pipe.txt")
                       (test-success-log
                        .
                        "server/built/test-success/pipe.txt")
                       (failure-log . #f)
                       (test-failure-log . #f)))
                (last-checked . 1522414513)
                (conflicts . ())
                (dependencies
                 .
                 ("typed-racket-lib"
                  "base"
                  "racket-doc"
                  "typed-racket-doc"
                  "scribble-lib"))
                (authors . ("ray.racine@gmail.com"))
                (last-edit . 1371342346)
                (description . "Iteratees in Typed Racket.")
                (implies . ())
                (modules
                 .
                 ((lib "pipe/pumps.rkt")
                  (lib "pipe/types.rkt")
                  (lib "pipe/filetank.rkt")
                  (lib "pipe/main.rkt")
                  (lib "pipe/pipes.rkt")
                  (lib "pipe/tanks.rkt")
                  (lib "pipe/scribblings/pipe.scrbl")))
                (versions
                 .
                 #hash((default
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/pipe/tree/master")
                                (checksum
                                 .
                                 "179b8f8ad92ced86ea8dacec607deb24aefc15aa")
                                (source
                                 .
                                 "https://gitlab.com/RayRacine/pipe.git")))))
                (search-terms
                 .
                 #hasheq((control . #t)
                         (:build-success: . #t)
                         (iteratee . #t)
                         (:docs: . #t)
                         (ring:1 . #t)
                         (author:ray.racine@gmail.com . #t)))
                (name . "pipe")
                (checksum . "179b8f8ad92ced86ea8dacec607deb24aefc15aa")
                (last-updated . 1502816260)
                (source . "https://gitlab.com/RayRacine/pipe.git")
                (tags . ("control" "iteratee"))
                (author . "ray.racine@gmail.com")
                (checksum-error . #f)
                (ring . 1)))
       ("wrap"
        .
        #hasheq((build
                 .
                 #hash((docs . (("none" "wrap-aws")))
                       (min-failure-log . #f)
                       (conflicts-log . #f)
                       (dep-failure-log . #f)
                       (success-log . #f)
                       (test-success-log . #f)
                       (failure-log . "server/built/fail/wrap.txt")
                       (test-failure-log . #f)))
                (last-checked . 1522414702)
                (conflicts . ())
                (dependencies
                 .
                 ("grip"
                  "base"
                  "grommet"
                  "gut"
                  "srfi-lite-lib"
                  "typed-racket-lib"
                  "scribble-lib"))
                (authors . ("ray.racine@gmail.com"))
                (last-edit . 1370447682)
                (description
                 .
                 "AWS API in Typed Racket.  Generally, AWS responses are parsed as structures.")
                (implies . ())
                (modules
                 .
                 ((lib "wrap/wrap/aws/dynamodb/config.rkt")
                  (lib "wrap/wrap/aws/iam/iam.rkt")
                  (lib "wrap/wrap/aws/dynamodb/invoke.rkt")
                  (lib "wrap/wrap/aws/dynamodb/query.rkt")
                  (lib "wrap/wrap/aws/dynamodb/scan.rkt")
                  (lib "wrap/wrap/aws/dynamodb/test.rkt")
                  (lib "wrap/wrap/aws/sts/config.rkt")
                  (lib "wrap/wrap/aws/swf/task.rkt")
                  (lib "wrap/wrap/aws/dynamodb/types.rkt")
                  (lib "wrap/wrap/aws/auth/authv2.rkt")
                  (lib "wrap/wrap/aws/credential.rkt")
                  (lib "wrap/wrap/aws/dynamodb/dynamodb.rkt")
                  (lib "wrap/wrap/aws/scribblings/wrap-aws.scrbl")
                  (lib "wrap/wrap/aws/swf/attrs.rkt")
                  (lib "wrap/wrap/aws/iam/actions.rkt")
                  (lib "wrap/wrap/aws/configuration.rkt")
                  (lib "wrap/wrap/aws/sts/sts.rkt")
                  (lib "wrap/wrap/aws/dynamodb/deletetable.rkt")
                  (lib "wrap/wrap/aws/sqs/private/listqueues.rkt")
                  (lib "wrap/wrap/aws/s3/types.rkt")
                  (lib "wrap/wrap/aws/auth/authv3.rkt")
                  (lib "wrap/wrap/aws/sqs/config.rkt")
                  (lib "wrap/wrap/aws/a2s/a2s.rkt")
                  (lib "wrap/wrap/aws/dynamodb/putitem.rkt")
                  (lib "wrap/wrap/aws/dynamodb/deleteitem.rkt")
                  (lib "wrap/wrap/aws/dynamodb/action.rkt")
                  (lib "wrap/wrap/aws/swf/logging.rkt")
                  (lib "wrap/wrap/aws/sqs/private/invoke.rkt")
                  (lib "wrap/wrap/aws/dynamodb/parse.rkt")
                  (lib "wrap/wrap/aws/dynamodb/error.rkt")
                  (lib "wrap/wrap/aws/sqs/sqs.rkt")
                  (lib "wrap/wrap/aws/s3/invoke.rkt")
                  (lib "wrap/wrap/aws/s3/response.rkt")
                  (lib "wrap/wrap/aws/swf/workflow.rkt")
                  (lib "wrap/wrap/aws/sts/session.rkt")
                  (lib "wrap/wrap/aws/swf/decision.rkt")
                  (lib "wrap/wrap/aws/swf/domain.rkt")
                  (lib "wrap/wrap/aws/sqs/private/sendmsg.rkt")
                  (lib "wrap/wrap/aws/dynamodb/describetable.rkt")
                  (lib "wrap/wrap/aws/swf/activity.rkt")
                  (lib "wrap/wrap/aws/dynamodb/updateitem.rkt")
                  (lib "wrap/wrap/aws/dynamodb/createtable.rkt")
                  (lib "wrap/wrap/aws/sqs/private/deletemsg.rkt")
                  (lib "wrap/wrap/aws/sqs/private/receivemsg.rkt")
                  (lib "wrap/wrap/aws/s3/objects.rkt")
                  (lib "wrap/wrap/aws/dynamodb/request.rkt")
                  (lib "wrap/wrap/aws/swf/types.rkt")
                  (lib "wrap/wrap/aws/s3/s3-uri.rkt")
                  (lib "wrap/wrap/aws/s3/configuration.rkt")
                  (lib "wrap/wrap/aws/misc.rkt")
                  (lib "wrap/wrap/aws/sts/error.rkt")
                  (lib "wrap/wrap/aws/a2s/search.rkt")
                  (lib "wrap/wrap/aws/dynamodb/listtable.rkt")
                  (lib "wrap/wrap/aws/simpledb/simpledb.rkt")
                  (lib "wrap/wrap/aws/swf/history.rkt")
                  (lib "wrap/wrap/aws/s3/buckets.rkt")
                  (lib "wrap/wrap/aws/dynamodb/response.rkt")
                  (lib "wrap/wrap/aws/auth.rkt")
                  (lib "wrap/wrap/aws/sts/response.rkt")
                  (lib "wrap/wrap/aws/simpledb/dberror.rkt")
                  (lib "wrap/wrap/aws/simpledb/config.rkt")
                  (lib "wrap/wrap/aws/dynamodb/getitem.rkt")))
                (versions
                 .
                 #hash((default
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/wrap/tree/master")
                                (checksum
                                 .
                                 "df42a596ca8ab0777101d00370f518f17f6afbe9")
                                (source
                                 .
                                 "https://gitlab.com/RayRacine/wrap.git")))))
                (search-terms
                 .
                 #hasheq((:docs-error: . #t)
                         (ring:1 . #t)
                         (AWS . #t)
                         (:build-fail: . #t)
                         (author:ray.racine@gmail.com . #t)
                         (API . #t)))
                (name . "wrap")
                (checksum . "df42a596ca8ab0777101d00370f518f17f6afbe9")
                (last-updated . 1502816529)
                (source . "https://gitlab.com/RayRacine/wrap.git")
                (tags . ("API" "AWS"))
                (author . "ray.racine@gmail.com")
                (checksum-error . #f)
                (ring . 1)))
       ("grommet"
        .
        #hasheq((build
                 .
                 #hash((docs
                        .
                        (("main" "grommet" "doc/grommet@grommet/index.html")))
                       (min-failure-log . #f)
                       (conflicts-log . #f)
                       (dep-failure-log . #f)
                       (success-log . "server/built/install/grommet.txt")
                       (test-success-log
                        .
                        "server/built/test-success/grommet.txt")
                       (failure-log . #f)
                       (test-failure-log . #f)))
                (last-checked . 1522414406)
                (conflicts . ())
                (dependencies
                 .
                 ("grip"
                  "typed-racket-lib"
                  "base"
                  "racket-doc"
                  "typed-racket-doc"
                  "scribble-lib"))
                (authors . ("ray.racine@gmail.com"))
                (last-edit . 1369839818)
                (description
                 .
                 "Crypto routines, MD5, SHA-1, SHA-256, HMAC as native Typed Racket implementations.")
                (implies . ())
                (modules
                 .
                 ((lib "grommet/scribblings/grommet.scrbl")
                  (lib "grommet/crypto/hash/sha256.rkt")
                  (lib "grommet/crypto/hmac.rkt")
                  (lib "grommet/crypto/base64.rkt")
                  (lib "grommet/crypto/private/util.rkt")
                  (lib "grommet/crypto/hash/sha1.rkt")
                  (lib "grommet/crypto/hash/md5.rkt")))
                (versions
                 .
                 #hash((default
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/grommet/tree/master")
                                (checksum
                                 .
                                 "bc3e2931a0e061187c0124ce32e1c10932c34da4")
                                (source
                                 .
                                 "https://gitlab.com/RayRacine/grommet.git")))))
                (search-terms
                 .
                 #hasheq((:build-success: . #t)
                         (crypto . #t)
                         (:docs: . #t)
                         (ring:1 . #t)
                         (author:ray.racine@gmail.com . #t)))
                (name . "grommet")
                (checksum . "bc3e2931a0e061187c0124ce32e1c10932c34da4")
                (last-updated . 1502816092)
                (source . "https://gitlab.com/RayRacine/grommet.git")
                (tags . ("crypto"))
                (author . "ray.racine@gmail.com")
                (checksum-error . #f)
                (ring . 1)))
       ("gut"
        .
        #hasheq((build
                 .
                 #hash((docs
                        .
                        (("salvage" "manual" "doc/manual@gut/index.html")
                         ("salvage" "gut" "doc/gut@gut/index.html")))
                       (min-failure-log . #f)
                       (conflicts-log . #f)
                       (dep-failure-log . #f)
                       (success-log . #f)
                       (test-success-log . #f)
                       (failure-log . "server/built/fail/gut.txt")
                       (test-failure-log . #f)))
                (last-checked . 1522414414)
                (conflicts . ())
                (dependencies
                 .
                 ("base"
                  "srfi-lite-lib"
                  "sxml"
                  "typed-racket-lib"
                  "typed-racket-more"
                  "grip"
                  "grommet"
                  "html-parsing"
                  "html-writing"
                  "json-parsing"
                  "racket-doc"
                  "scribble-lib"
                  "typed-racket-doc"))
                (authors . ("ray.racine@gmail.com"))
                (last-edit . 1369259740)
                (description
                 .
                 "Web related functionality in Typed Racket.  Includes full HTTP 1.1 client, UUIDs, Consumer OAuth, Json, XML formats.")
                (implies . ())
                (modules
                 .
                 ((lib "gut/format/xml/util.rkt")
                  (lib "gut/http/parse.rkt")
                  (lib "gut/http/scribblings/http.scrbl")
                  (lib "gut/uri/parse.rkt")
                  (lib "gut/uri/urichar.rkt")
                  (lib "gut/format/xml/sxml.rkt")
                  (lib "gut/format/json/tjson.rkt")
                  (lib "gut/http/header.rkt")
                  (lib "gut/uri/url/url.rkt")
                  (lib "gut/oauth/oauth.rkt")
                  (lib "gut/uri/parse-util.rkt")
                  (lib "gut/http/param.rkt")
                  (lib "gut/http/encode.rkt")
                  (lib "gut/http/mimetype-const.rkt")
                  (lib "gut/http/http11.rkt")
                  (lib "gut/scribblings/gut.scrbl")
                  (lib "gut/uri/url/show.rkt")
                  (lib "gut/format/rss/rss20/rss.rkt")
                  (lib "gut/http/encoding.rkt")
                  (lib "gut/uri/scribblings/uri.scrbl")
                  (lib "gut/oauth/encode.rkt")
                  (lib "gut/http/scribblings/manual.scrbl")
                  (lib "gut/http/cookie.rkt")
                  (lib "gut/format/json/json.rkt")
                  (lib "gut/http/proxy.rkt")
                  (lib "gut/uri/show.rkt")
                  (lib "gut/uri/url/parse.rkt")
                  (lib "gut/uri/url/urlchar.rkt")
                  (lib "gut/http/heading.rkt")
                  (lib "gut/format/html/html.rkt")
                  (lib "gut/http/mimetype.rkt")
                  (lib "gut/uri/url/qparams.rkt")
                  (lib "gut/uri/types.rkt")
                  (lib "gut/http/scribblings/webkit.scrbl")
                  (lib "gut/uuid/uuid.rkt")
                  (lib "gut/uri/url/types.rkt")
                  (lib "gut/uri/url/util.rkt")))
                (versions
                 .
                 #hash((default
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/gut/tree/master")
                                (checksum
                                 .
                                 "962ea196fade89b6da7a5d5cc07ea89137809373")
                                (source
                                 .
                                 "https://gitlab.com/RayRacine/gut.git")))))
                (search-terms
                 .
                 #hasheq((xml . #t)
                         (json . #t)
                         (web . #t)
                         (:docs-error: . #t)
                         (:docs: . #t)
                         (ring:1 . #t)
                         (http . #t)
                         (:build-fail: . #t)
                         (author:ray.racine@gmail.com . #t)
                         (oauth . #t)))
                (name . "gut")
                (checksum . "962ea196fade89b6da7a5d5cc07ea89137809373")
                (last-updated . 1502816109)
                (source . "https://gitlab.com/RayRacine/gut.git")
                (tags . ("http" "json" "oauth" "web" "xml"))
                (author . "ray.racine@gmail.com")
                (checksum-error . #f)
                (ring . 1)))
       ("munger"
        .
        #hasheq((build
                 .
                 #hash((docs . ())
                       (min-failure-log . #f)
                       (conflicts-log . #f)
                       (dep-failure-log . #f)
                       (success-log . "server/built/install/munger.txt")
                       (test-success-log
                        .
                        "server/built/test-success/munger.txt")
                       (failure-log . #f)
                       (test-failure-log . #f)))
                (last-checked . 1522414437)
                (conflicts . ())
                (dependencies . ("grip" "typed-racket-lib" "base" "pipe"))
                (authors . ("ray.racine@gmail.com"))
                (last-edit . 1369950652)
                (description . "An R Dataframe structure in Typed Racket.")
                (implies . ())
                (modules
                 .
                 ((lib "munger/load/frame-builder.rkt")
                  (lib "munger/frame/series.rkt")
                  (lib "munger/load/csv-delimited.rkt")
                  (lib "munger/format/tabbed/parser.rkt")
                  (lib "munger/frame/numeric-series.rkt")
                  (lib "munger/frame/categorical-series-ops.rkt")
                  (lib "munger/format/fixed/parser.rkt")
                  (lib "munger/frame/categorical-series-builder.rkt")
                  (lib "munger/load/schema-syntax.rkt")
                  (lib "munger/frame/indexed-series.rkt")
                  (lib "munger/format/tabbed/reader.rkt")
                  (lib "munger/frame/gen-nseries.rkt")
                  (lib "munger/frame/integer-series-builder.rkt")
                  (lib "munger/format/convert.rkt")
                  (lib "munger/load/schema.rkt")
                  (lib "munger/format/csv/csv.rkt")
                  (lib "munger/format/csv/layout.rkt")
                  (lib "munger/frame/integer-series.rkt")
                  (lib "munger/frame/settings.rkt")
                  (lib "munger/stats/statistics.rkt")
                  (lib "munger/load/sample.rkt")
                  (lib "munger/format/csv/parser.rkt")
                  (lib "munger/frame/frame-join.rkt")
                  (lib "munger/frame/series-iter.rkt")
                  (lib "munger/frame/types.rkt")
                  (lib "munger/load/types.rkt")
                  (lib "munger/main.rkt")
                  (lib "munger/frame/date.rkt")
                  (lib "munger/frame/numeric-series-builder.rkt")
                  (lib "munger/format/layout.rkt")
                  (lib "munger/frame/categorical-series.rkt")
                  (lib "munger/format/layout-scratch.rkt")
                  (lib "munger/format/fixed/layout.rkt")
                  (lib "munger/frame/series-builder.rkt")
                  (lib "munger/format/tabbed/layout.rkt")
                  (lib "munger/frame/frame-print.rkt")
                  (lib "munger/load/load.rkt")
                  (lib "munger/frame/series-description.rkt")
                  (lib "munger/load/delimited-common.rkt")
                  (lib "munger/format/layout-types.rkt")
                  (lib "munger/frame/builders.rkt")
                  (lib "munger/frame/bugs.rkt")
                  (lib "munger/stats/tabulate.rkt")
                  (lib "munger/frame/frame.rkt")
                  (lib "munger/frame/numseries-scratch.rkt")
                  (lib "munger/load/tab-delimited.rkt")))
                (versions
                 .
                 #hash((default
                        .
                        #hasheq((source_url
                                 .
                                 "http://gitlab.com/RayRacine/munger/tree/master")
                                (checksum
                                 .
                                 "d8f58f0256d66c681faf7f5d21df93b594093500")
                                (source
                                 .
                                 "https://gitlab.com/RayRacine/munger.git")))))
                (search-terms
                 .
                 #hasheq((:build-success: . #t)
                         (data . #t)
                         (ring:1 . #t)
                         (author:ray.racine@gmail.com . #t)
                         (dataframe . #t)))
                (name . "munger")
                (checksum . "d8f58f0256d66c681faf7f5d21df93b594093500")
                (last-updated . 1502816189)
                (source . "https://gitlab.com/RayRacine/munger.git")
                (tags . ("data" "dataframe"))
                (author . "ray.racine@gmail.com")
                (checksum-error . #f)
                (ring . 1)))
      ("ansi"
       .
       #hasheq((nix-sha256
                .
                "1rm4bm8h04paa23j059w7fak2gim3zkxcq4dy65rq4r6xqyvwdln")
               (dependencies . ("base" "dynext-lib" "make" "rackunit-lib"))
               (authors . ("tonygarnockjones@gmail.com"))
               (description . "ANSI and VT10x escape sequences for Racket.")
               (name . "ansi")
               (checksum . "c2454badf7d9401425bab91ba44e4287e690607b")
               (source . "github://github.com/tonyg/racket-ansi/master")
               (author . "tonygarnockjones@gmail.com"))))))
