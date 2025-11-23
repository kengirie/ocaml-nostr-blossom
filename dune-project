(lang dune 3.20)

(name ocaml-nostr-blossom)

(generate_opam_files true)

(source
 (github username/reponame))

(authors "Author Name <author@example.com>")

(maintainers "Maintainer Name <maintainer@example.com>")

(license LICENSE)

(documentation https://url/to/documentation)

(package
 (name ocaml-nostr-blossom)
 (synopsis "A short synopsis")
 (description "A longer description")
 (depends ocaml piaf eio eio_main digestif checkseum alcotest)
 (tags
  ("add topics" "to describe" your project)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
