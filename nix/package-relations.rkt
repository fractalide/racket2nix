#lang racket

(provide (all-defined-out))

(define (cycle-name cycle)
  (define long-name (string-join cycle "-"))
  (if (<= (string-length long-name) 64)
    long-name
    (string-append (substring long-name 0 61) "...")))

(define (quick-transitive-dependencies name package done catalog)
  (define deps (hash-ref package 'dependency-names))
  (cond
   [(for/and ([dep deps])
      (unless (hash-ref catalog dep #f)
        (raise-user-error (format "Invalid catalog: Package ~a has unresolved dependency ~a.~n"
          name dep)))
      (hash-ref done dep #f))
    (define new-done
      (hash-set done name (hash-set package 'transitive-dependency-names
        (remove-duplicates (append* (cons (hash-ref package 'dependency-names) (map
          (lambda (dep) (hash-ref (hash-ref done dep) 'transitive-dependency-names)) deps)))))))
    (values #hash() new-done)]
   [else
    (define new-todo (for/fold ([new-todo #hash()]) ([todo-name (cons name deps)])
      (if (hash-ref done todo-name #f)
        new-todo
        (hash-set new-todo todo-name (hash-ref catalog todo-name)))))
          (values new-todo done)]))

(define (hash-merge . hs)
  (for/fold ([h (car hs)]) ([k-v (append* (map hash->list (cdr hs)))])
    (match-define (cons k v) k-v)
    (hash-set h k v)))

(define (calculate-transitive-dependencies catalog names)
  (let loop ([todo (make-immutable-hash (map (lambda (name) (cons name (hash-ref catalog name))) names))]
             [done #hash()])
    (cond
     [(hash-empty? todo) done]
     [else
      (define-values (new-todo new-done) (for/fold ([todo #hash()] [done done]) ([(name package) (in-hash todo)])
        (define-values (part-todo part-done) (quick-transitive-dependencies name package done catalog))
        (values (hash-merge todo part-todo) (hash-merge done part-done))))
      (if (and (equal? new-todo todo) (equal? new-done done)) ; only cycles left
          (hash-merge new-todo new-done)
          (loop new-todo new-done))])))

(define (merge-cycles name my-cycle other-cycles found-cycles breadcrumbs memo known-cycles)
  (for/fold
    ([my-cycle my-cycle] [other-cycles other-cycles] [memo memo] [known-cycles known-cycles])
    ([cycle found-cycles])
    (cond
     [(member name cycle)
      (define new-my-cycle (sort (set-union my-cycle cycle) string<?))
      (values new-my-cycle other-cycles
        (set-union memo new-my-cycle)
        (normalize-cycles (list new-my-cycle) known-cycles))]
     [(pair? (set-intersect breadcrumbs cycle))
      (define new-cycle (sort (cons name cycle) string<?))
      (define new-other-cycles (set-union '() (cons new-cycle other-cycles)))
      (values my-cycle new-other-cycles
        (apply set-union (list* memo new-other-cycles))
        (normalize-cycles new-other-cycles known-cycles))]
     [else
      (define new-other-cycles (set-union (list cycle) other-cycles))
      (values my-cycle new-other-cycles
        (apply set-union (list* memo new-other-cycles))
        (normalize-cycles new-other-cycles known-cycles))])))

(define (normalize-cycles . cycleses)
  (define cycles (apply set-union cycleses))
  (remove '() (set-union '() (map
    (lambda (cycle) (for/fold ([acc cycle]) ([other-cycle cycles])
      (if (null? (set-intersect acc other-cycle))
          acc
          (sort (set-union '() acc other-cycle) string<?))))
    cycles))))

(define (find-cycles catalog name package breadcrumbs memo known-cycles)
  (define deps (hash-ref package 'dependency-names))

  (for/fold ([my-cycle '()] [other-cycles '()] [memo memo] [known-cycles known-cycles]
             #:result (append (if (pair? my-cycle) (list my-cycle) '()) other-cycles))
            ([dep-name deps])
    (define dep (hash-ref catalog dep-name))
    (cond
     [(member dep-name breadcrumbs)
      (define new-my-cycle (sort
        (set-union my-cycle (list name dep-name))
        string<?))
      (values new-my-cycle other-cycles
        (set-union memo new-my-cycle)
        (normalize-cycles (list new-my-cycle) other-cycles known-cycles))]
     [(member dep-name memo) ; known cycle, join if relevant
      (define maybe-relevant-cycle (for/or ([cycle known-cycles])
        (define intersection (set-intersect (cons name breadcrumbs) cycle))
        (and (pair? intersection) intersection)))
      (cond
       [maybe-relevant-cycle
        (define new-my-cycle (sort
          (set-union my-cycle (list name) maybe-relevant-cycle)
          string<?))
        (values new-my-cycle other-cycles
          (set-union memo new-my-cycle)
          (normalize-cycles (list new-my-cycle) other-cycles known-cycles))]
       [else
        (values my-cycle other-cycles memo known-cycles)])]
     [(hash-ref dep 'transitive-dependency-names #f) ; a dep with a nice tree, no cycles
      (values my-cycle other-cycles memo known-cycles)]
     [else
      (define found-cycles (find-cycles catalog dep-name dep (cons name breadcrumbs) memo known-cycles))
      (merge-cycles name my-cycle other-cycles found-cycles breadcrumbs memo known-cycles)])))

; assumes catalog has has calculate-transitive-dependencies run on it
(define (calculate-cycles catalog names)
  (for/fold ([cycles '()]) ([name names])
    (define memo (apply set-union (cons '() cycles)))

    (define new-cycles (find-cycles catalog names (hash-ref catalog name) '()
                                    memo cycles))
    (normalize-cycles cycles new-cycles)))

(define (find-transdeps-avoid-cycles catalog name cycles)
  (define my-cycle (or (for/or ([cycle cycles]) (and (member name cycle) cycle)) '()))
  (define package (hash-ref catalog name))
  (define dep-names (remove* my-cycle (hash-ref package 'dependency-names)))

  (define quick-transdeps (hash-ref package 'transitive-dependency-names #f))

  (define-values (new-transdeps new-catalog) (cond
   [quick-transdeps (values quick-transdeps catalog)]
   [else (for/fold
    ([transdeps dep-names] [memo-catalog catalog])
    ([dep-name dep-names])

    (define-values (sub-transdeps new-catalog)
      (find-transdeps-avoid-cycles memo-catalog dep-name cycles))
    (values (set-union transdeps sub-transdeps) new-catalog))]))

  (values
    new-transdeps
    (hash-set new-catalog name (hash-set package 'transitive-dependency-names new-transdeps))))

(define (calculate-package-relations catalog (package-names '()))
  (define names (if (pair? package-names)  package-names (hash-keys catalog)))
  (define catalog-with-transdeps (calculate-transitive-dependencies catalog names))

  (define cycles (calculate-cycles catalog names))

  (define catalog-with-transdeps-and-cycles (for/fold ([acc-catalog catalog]) ([name (append* names cycles)])
    (define circdeps (or (for/or ([cycle cycles]) (if (member name cycle) cycle #f)) '()))
    (define-values (transdeps new-catalog) (find-transdeps-avoid-cycles acc-catalog name cycles))

    (hash-set new-catalog name (hash-set* (hash-ref new-catalog name)
      'transitive-dependency-names (remove* circdeps transdeps)
      'circular-dependencies circdeps))))

  (define reified-cycles (for/hash ([cycle cycles])
    (define name (cycle-name cycle))
    (define cycle-packages (map (curry hash-ref catalog-with-transdeps-and-cycles) cycle))
    (define package (make-hash (list
      (cons 'name name)
      (cons 'reverse-circular-build-inputs cycle)
      (cons 'dependency-names
            (sort (apply set-union
                    (map (lambda (pkg) (hash-ref pkg 'dependency-names)) cycle-packages))
                  string<?))
      (cons 'transitive-dependency-names
            (sort (apply set-union
                    (map (lambda (pkg) (hash-ref pkg 'transitive-dependency-names (lambda ()
                                         (error (format "pkg ~a no transdeps~n" (hash-ref pkg 'name))))))
                    cycle-packages))
                  string<?)))))
    (values name package)))

  (define names-with-transdeps
    (apply set-union (cons names (append cycles (map
      (lambda (name) (hash-ref (hash-ref catalog-with-transdeps-and-cycles name) 'transitive-dependency-names))
    (append* names cycles))))))

  (define catalog-with-reified-cycles (for/hash ([name names-with-transdeps])
    (define package (hash-ref catalog-with-transdeps-and-cycles name))
    (define transdeps (hash-ref package 'transitive-dependency-names))
    (define cycles (remove '() (remove-duplicates (map
      (lambda (name) (hash-ref (hash-ref catalog-with-transdeps-and-cycles name) 'circular-dependencies '()))
      (cons name transdeps)))))
    (define cycle-names (map cycle-name cycles))
    (define reified-cycle-transdeps (append* cycle-names (map
      (compose (curryr hash-ref 'transitive-dependency-names) (curry hash-ref reified-cycles))
      cycle-names)))
    (define normalized-transdeps (remove name (sort (set-union transdeps reified-cycle-transdeps) string<?)))
    (values name (hash-set package 'transitive-dependency-names normalized-transdeps))))

  (make-immutable-hash (append (hash->list catalog-with-reified-cycles) (hash->list reified-cycles))))
