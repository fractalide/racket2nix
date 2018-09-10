#lang racket

(require datalog)

(provide (all-defined-out))

(define (package-rules)
  (define rules (make-theory))
  (datalog rules
    (! (:- (transdepends X Y)
           (depends X Y)))
    (! (:- (transdepends X Z)
           (transdepends X Y)
           (transdepends Y Z)))
    (! (:- (cycle X Y)
           (stored-transdepends X Y)
           (stored-transdepends Y X))))
  rules)

(define (sort-and-extract-X result)
  (sort (map (match-lambda [(hash-table ('X v)) v])
             result)
        string<?))

(define (cycle-name cycle)
  (define long-name (string-join cycle "-"))
  (if (<= (string-length long-name) 32)
    long-name
    (string-append (substring long-name 0 29) "...")))

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

(define (calculate-package-relations catalog)
  (define rules (package-rules))

  (for ([(name package) (in-hash catalog)])
    (define deps (hash-ref package 'dependency-names))
    (for ([dep deps])
      (datalog rules (! (depends #,(datum-intern-literal name) #,(datum-intern-literal dep))))))

  (time (for ([(name package) (in-hash catalog)])
    (define transdeps (sort-and-extract-X
      (datalog rules (? (transdepends #,(datum-intern-literal name) X)))))

    (for ([dep transdeps])
      (datalog rules (! (stored-transdepends #,(datum-intern-literal name) #,dep))))))

  (define catalog-with-transdeps-and-cycles (time (for/hash ([(name package) (in-hash catalog)])
    (define transdeps (sort-and-extract-X
      (datalog rules (? (stored-transdepends #,(datum-intern-literal name) X)))))

    (define circdeps (sort-and-extract-X
      (datalog rules (? (cycle #,(datum-intern-literal name) X)))))

    (values name
            (hash-set (hash-set package 'circular-dependencies circdeps)
              'transitive-dependency-names (remove* circdeps transdeps))))))

  (define cycles (remove-duplicates
    (map (lambda (package) (hash-ref package 'circular-dependencies))
         (hash-values catalog-with-transdeps-and-cycles))))

  (define reified-cycles (for/hash ([cycle cycles])
    (define name (cycle-name cycle))
    (define circular-packages (map (curry hash-ref catalog-with-transdeps-and-cycles) cycle))
    (define package (make-hash (list
      (cons 'name name)
      (cons 'reverse-circular-build-inputs cycle)
      (cons 'dependency-names
            (sort (remove-duplicates (append*
                    (map (lambda (pkg) (hash-ref pkg 'dependency-names)) circular-packages)))
                  string<?))
      (cons 'transitive-dependency-names
            (sort (remove-duplicates (append*
                    (map (lambda (pkg) (hash-ref pkg 'transitive-dependency-names)) circular-packages)))
                  string<?)))))
    (values name package)))

  (define catalog-with-reified-cycles (for/hash ([(name package) (in-hash catalog-with-transdeps-and-cycles)])
    (define cycle (hash-ref package 'circular-dependencies))
    (define transdeps (hash-ref package 'transitive-dependency-names))
    (if (null? cycle)
        (values name package)
        (values name (hash-set package 'transitive-dependency-names (cons (cycle-name cycle) transdeps))))))

  (make-immutable-hash (append (hash->list catalog-with-reified-cycles) (hash->list reified-cycles))))
