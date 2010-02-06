;; Library: sxml-match
;; Author: Jim Bender
;; Version: 1.0a, Portable Syntax-case version for (Petite) Chez Scheme and SISC
;;
;; Copyright 2005, Jim Bender
;; sxml-match is released under the MIT License
;;
(module portability (let/ec)
  
  ; under Chez Scheme and Petite Chez Scheme, use call/1cc
  (define-syntax let/ec
    (syntax-rules ()
      [(let/ec name exp0 exp ...)
       (call/cc (lambda (name) exp0 exp ...))]))
  
  )

(module syntax-portability (raise-syntax-error let-values)
  
  (define (raise-syntax-error flag msg exp sub)
    (syntax-error sub msg))
  
  ; included from the SRFI-11 reference implementation
  (define-syntax let-values
    (syntax-rules ()
      ((let-values (?binding ...) ?body0 ?body1 ...)
       (let-values "bind" (?binding ...) () (begin ?body0 ?body1 ...)))
      
      ((let-values "bind" () ?tmps ?body)
       (let ?tmps ?body))
      
      ((let-values "bind" ((?b0 ?e0) ?binding ...) ?tmps ?body)
       (let-values "mktmp" ?b0 ?e0 () (?binding ...) ?tmps ?body))
      
      ((let-values "mktmp" () ?e0 ?args ?bindings ?tmps ?body)
       (call-with-values 
        (lambda () ?e0)
        (lambda ?args
          (let-values "bind" ?bindings ?tmps ?body))))
      
      ((let-values "mktmp" (?a . ?b) ?e0 (?arg ...) ?bindings (?tmp ...) ?body)
       (let-values "mktmp" ?b ?e0 (?arg ... x) ?bindings (?tmp ... (?a x)) ?body))
      
      ((let-values "mktmp" ?a ?e0 (?arg ...) ?bindings (?tmp ...) ?body)
       (call-with-values
        (lambda () ?e0)
        (lambda (?arg ... . x)
          (let-values "bind" ?bindings (?tmp ... (?a x)) ?body))))))
  
  )

(module srfi-1-compat (fold-right filter)
  
  ; included from the SRFI-1 reference implementation
  ; fold-right has been simplified to deal with the single list case only.
  
  (define (fold-right kons knil lis1)
    (let recur ((lis lis1))
      (if (null? lis) knil
          (let ((head (car lis)))
            (kons head (recur (cdr lis)))))))
  
  (define (filter pred lis)
    (let recur ((lis lis))
      (if (null? lis) lis
          (let ((head (car lis))
                (tail (cdr lis)))
            (if (pred head)
                (let ((new-tail (recur tail)))
                  (if (eq? tail new-tail) lis
                      (cons head new-tail)))
                (recur tail))))))
  )

(module sxml-accessors (nodeset?
                        xml-element-tag
                        xml-element-attributes
                        xml-element-contents
                        match-xml-attribute
                        filter-attributes)
  
  (import srfi-1-compat)
  
  (define (nodeset? x)
    (or (and (pair? x) (not (symbol? (car x)))) (null? x)))
  
  (define (xml-element-tag s)
    (if (and (pair? s) (symbol? (car s)))
        (car s)
        (error 'xml-element-tag "expected an xml-element, given" s)))
  
  (define (xml-element-attributes s)
    (if (and (pair? s) (symbol? (car s)))
        (fold-right (lambda (a b)
                      (if (and (pair? a) (eq? '@ (car a)))
                          (if (null? b)
                              (filter (lambda (i) (not (and (pair? i) (eq? '@ (car i))))) (cdr a))
                              (fold-right (lambda (c d)
                                            (if (and (pair? c) (eq? '@ (car c)))
                                                d
                                                (cons c d)))
                                          b (cdr a)))
                          b))
                    '()
                    (cdr s))
        (error 'xml-element-attributes "expected an xml-element, given" s)))
  
  (define (xml-element-contents s)
    (if (and (pair? s) (symbol? (car s)))
        (filter (lambda (i)
                  (not (and (pair? i) (eq? '@ (car i)))))
                (cdr s))
        (error 'xml-element-contents "expected an xml-element, given" s)))
  
  (define (match-xml-attribute key l)
    (if (not (pair? l))
        #f
        (if (eq? (car (car l)) key)
            (car l)
            (match-xml-attribute key (cdr l)))))
  
  (define (filter-attributes keys lst)
    (if (null? lst)
        '()
        (if (member (caar lst) keys)
            (filter-attributes keys (cdr lst))
            (cons (car lst) (filter-attributes keys (cdr lst))))))
  
  )

(module internal-compile-clause (compile-clause)
  
  (import syntax-portability)
  (import sxml-accessors)
  
  (define-syntax compile-clause
    (lambda (stx)
      (letrec
          ([sxml-match-syntax-error
            (lambda (msg exp sub)
              (raise-syntax-error #f msg (with-syntax ([s exp]) (syntax (sxml-match s))) sub))]
           [ellipsis?
            (lambda (stx)
              (and (identifier? stx) (eq? '... (syntax-object->datum stx))))]
           [literal?
            (lambda (stx)
              (let ([x (syntax-object->datum stx)])
                (or (string? x)
                    (char? x)
                    (number? x)
                    (boolean? x))))]
           [keyword?
            (lambda (stx)
              (and (identifier? stx)
                   (let ([str (symbol->string (syntax-object->datum stx))])
                     (char=? #\: (string-ref str (- (string-length str) 1))))))]
           [extract-cata-fun
            (lambda (cf)
              (syntax-case cf ()
                [#f #f]
                [other cf]))]
           [add-pat-var
            (lambda (pvar pvar-lst)
              (define (check-pvar lst)
                (if (null? lst)
                    (void)
                    (if (bound-identifier=? (car lst) pvar)
                        (sxml-match-syntax-error "duplicate pattern variable not allowed"
                                                 stx
                                                 pvar)
                        (check-pvar (cdr lst)))))
              (check-pvar pvar-lst)
              (cons pvar pvar-lst))]
           [add-cata-def
            (lambda (depth cvars cfun ctemp cdefs)
              (cons (list depth cvars cfun ctemp) cdefs))]
           [process-cata-exp
            (lambda (depth cfun ctemp)
              (if (= depth 0)
                  (with-syntax ([cf cfun]
                                [ct ctemp])
                    (syntax (cf ct)))
                  (let ([new-ctemp (car (generate-temporaries (list ctemp)))])
                    (with-syntax ([ct ctemp]
                                  [nct new-ctemp]
                                  [body (process-cata-exp (- depth 1) cfun new-ctemp)])
                      (syntax (map (lambda (nct) body) ct))))))]
           [process-cata-defs
            (lambda (cata-defs body)
              (if (null? cata-defs)
                  body
                  (with-syntax ([(cata-binding ...)
                                 (map (lambda (def)
                                        (with-syntax ([bvar (cadr def)]
                                                      [bval (process-cata-exp (car def)
                                                                              (caddr def)
                                                                              (cadddr def))])
                                          (syntax (bvar bval))))
                                      cata-defs)]
                                [body-stx body])
                    (syntax (let-values (cata-binding ...)
                              body-stx)))))]
           [cata-defs->pvar-lst
            (lambda (lst)
              (if (null? lst)
                  '()
                  (let iter ([items (cadr (car lst))])
                    (syntax-case items ()
                      [() (cata-defs->pvar-lst (cdr lst))]
                      [(fst . rst) (cons (syntax fst) (iter (syntax rst)))]))))]
           [process-output-action
            (lambda (action dotted-vars)
              (define (finite-lst? lst)
                (syntax-case lst ()
                  (item
                   (identifier? (syntax item))
                   #f)
                  (()
                   #t)
                  ((fst dots . rst)
                   (ellipsis? (syntax dots))
                   #f)
                  ((fst . rst)
                   (finite-lst? (syntax rst)))))
              (define (expand-lst lst)
                (syntax-case lst ()
                  [() (syntax '())]
                  [item
                   (identifier? (syntax item))
                   (syntax item)]
                  [(fst dots . rst)
                   (ellipsis? (syntax dots))
                   (with-syntax ([exp-lft (expand-dotted-item
                                           (process-output-action (syntax fst)
                                                                  dotted-vars))]
                                 [exp-rgt (expand-lst (syntax rst))])
                     (syntax (append exp-lft exp-rgt)))]
                  [(fst . rst)
                   (with-syntax ([exp-lft (process-output-action (syntax fst)
                                                                 dotted-vars)]
                                 [exp-rgt (expand-lst (syntax rst))])
                     (syntax (cons exp-lft exp-rgt)))]))
              (define (member-var? var lst)
                (let iter ([lst lst])
                  (if (null? lst)
                      #f
                      (if (or (bound-identifier=? var (car lst))
                              (free-identifier=? var (car lst)))
                          #t
                          (iter (cdr lst))))))
              (define (dotted-var? var)
                (member-var? var dotted-vars))
              (define (merge-pvars lst1 lst2)
                (if (null? lst1)
                    lst2
                    (if (member-var? (car lst1) lst2)
                        (merge-pvars (cdr lst1) lst2)
                        (cons (car lst1) (merge-pvars (cdr lst1) lst2)))))
              (define (select-dotted-vars x)
                (define (walk-quasi-body y)
                  (syntax-case y (unquote unquote-splicing)
                    [((unquote a) . rst)
                     (merge-pvars (select-dotted-vars (syntax a))
                                  (walk-quasi-body (syntax rst)))]
                    [((unquote-splicing a) . rst)
                     (merge-pvars (select-dotted-vars (syntax a))
                                  (walk-quasi-body (syntax rst)))]
                    [(fst . rst)
                     (merge-pvars (walk-quasi-body (syntax fst))
                                  (walk-quasi-body (syntax rst)))]
                    [other
                     '()]))
                (syntax-case x (quote quasiquote)
                  [(quote . rst) '()]
                  [(quasiquote . rst) (walk-quasi-body (syntax rst))]
                  [(fst . rst)
                   (merge-pvars (select-dotted-vars (syntax fst))
                                (select-dotted-vars (syntax rst)))]
                  [item
                   (and (identifier? (syntax item))
                        (dotted-var? (syntax item)))
                   (list (syntax item))]
                  [item '()]))
              (define (expand-dotted-item item)
                (let ([dvars (select-dotted-vars item)])
                  (syntax-case item ()
                    [x
                     (identifier? (syntax x))
                     (syntax x)]
                    [x (with-syntax ([(dv ...) dvars])
                         (syntax (map (lambda (dv ...) x) dv ...)))])))
              (define (expand-quasiquote-body x)
                (syntax-case x (unquote unquote-splicing quasiquote)
                  [(quasiquote . rst) (process-quasiquote x)]
                  [(unquote item)
                   (with-syntax ([expanded-item (process-output-action (syntax item)
                                                                       dotted-vars)])
                     (syntax (unquote expanded-item)))]
                  [(unquote-splicing item)
                   (with-syntax ([expanded-item (process-output-action (syntax item)
                                                                       dotted-vars)])
                     (syntax (unquote-splicing expanded-item)))]
                  [((unquote item) dots . rst)
                   (ellipsis? (syntax dots))
                   (with-syntax ([expanded-item (expand-dotted-item 
                                                 (process-output-action (syntax item)
                                                                        dotted-vars))]
                                 [expanded-rst (expand-quasiquote-body (syntax rst))])
                     (syntax ((unquote-splicing expanded-item) . expanded-rst)))]
                  [(item dots . rst)
                   (ellipsis? (syntax dots))
                   (with-syntax ([expanded-item (expand-dotted-item 
                                                 (process-output-action (syntax (quasiquote item))
                                                                        dotted-vars))]
                                 [expanded-rst (expand-quasiquote-body (syntax rst))])
                     (syntax ((unquote-splicing expanded-item) . expanded-rst)))]
                  [(fst . rst)
                   (with-syntax ([expanded-fst (expand-quasiquote-body (syntax fst))]
                                 [expanded-rst (expand-quasiquote-body (syntax rst))])
                     (syntax (expanded-fst . expanded-rst)))]
                  [other x]))
              (define (process-quasiquote x)
                (syntax-case x ()
                  [(quasiquote term) (with-syntax ([expanded-body (expand-quasiquote-body (syntax term))])
                                       (syntax (quasiquote expanded-body)))]
                  [else (sxml-match-syntax-error "bad quasiquote-form"
                                                 stx
                                                 x)]))
              (syntax-case action (quote quasiquote)
                [(quote . rst) action]
                [(quasiquote . rst) (process-quasiquote action)]
                [(fst . rst) (if (finite-lst? action)
                                 (with-syntax ([exp-lft (process-output-action (syntax fst) dotted-vars)]
                                               [exp-rgt (process-output-action (syntax rst) dotted-vars)])
                                   (syntax (exp-lft . exp-rgt)))
                                 (with-syntax ([exp-lft (process-output-action (syntax fst)
                                                                               dotted-vars)]
                                               [exp-rgt (expand-lst (syntax rst))])
                                   (syntax (apply exp-lft exp-rgt))))]
                [item action]))]
           [compile-element-pat
            (lambda (ele exp nextp fail-k pvar-lst depth cata-fun cata-defs dotted-vars)
              (syntax-case ele (@)
                [(tag (@ . attr-items) . items)
                 (identifier? (syntax tag))
                 (let ([attr-exp (car (generate-temporaries (list exp)))]
                       [body-exp (car (generate-temporaries (list exp)))])
                   (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-attr-list (syntax attr-items)
                                                    (syntax items)
                                                    attr-exp
                                                    body-exp
                                                    '()
                                                    nextp
                                                    fail-k
                                                    pvar-lst
                                                    depth
                                                    cata-fun
                                                    cata-defs
                                                    dotted-vars)])
                     (values (with-syntax ([x exp]
                                           [ax attr-exp]
                                           [bx body-exp]
                                           [body tests]
                                           [fail-to fail-k])
                               (syntax (if (and (pair? x) (eq? 'tag (xml-element-tag x)))
                                           (let ([ax (xml-element-attributes x)]
                                                 [bx (xml-element-contents x)])
                                             body)
                                           (fail-to))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [(tag . items)
                 (identifier? (syntax tag))
                 (let ([body-exp (car (generate-temporaries (list exp)))])
                   (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-item-list (syntax items)
                                                    body-exp
                                                    nextp
                                                    fail-k
                                                    #t
                                                    pvar-lst
                                                    depth
                                                    cata-fun
                                                    cata-defs
                                                    dotted-vars)])
                     (values (with-syntax ([x exp]
                                           [bx body-exp]
                                           [body tests]
                                           [fail-to fail-k])
                               (syntax (if (and (pair? x) (eq? 'tag (xml-element-tag x)))
                                           (let ([bx (xml-element-contents x)])
                                             body)
                                           (fail-to))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]))]
           [compile-end-element
            (lambda (exp nextp fail-k pvar-lst cata-defs dotted-vars)
              (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                            (nextp pvar-lst cata-defs dotted-vars)])
                (values (with-syntax ([x exp]
                                      [body next-tests]
                                      [fail-to fail-k])
                          (syntax (if (null? x) body (fail-to))))
                        new-pvar-lst
                        new-cata-defs
                        new-dotted-vars)))]
           [compile-attr-list
            (lambda (attr-lst body-lst attr-exp body-exp attr-key-lst nextp fail-k pvar-lst depth cata-fun cata-defs dotted-vars)
              (syntax-case attr-lst (unquote ->)
                [(unquote var)
                 (identifier? (syntax var))
                 (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                               (compile-item-list body-lst
                                                  body-exp
                                                  nextp
                                                  fail-k
                                                  #t
                                                  (add-pat-var (syntax var) pvar-lst)
                                                  depth
                                                  cata-fun
                                                  cata-defs
                                                  dotted-vars)])
                   (values (with-syntax ([ax attr-exp]
                                         [matched-attrs attr-key-lst]
                                         [body tests])
                             (syntax (let ([var (filter-attributes 'matched-attrs ax)])
                                       body)))
                           new-pvar-lst
                           new-cata-defs
                           new-dotted-vars))]
                [((atag [(unquote [cata -> cvar ...]) default]) . rst)
                 (identifier? (syntax atag))
                 (let ([ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-attr-list (syntax rst)
                                                    body-lst
                                                    attr-exp
                                                    body-exp
                                                    (cons (syntax atag) attr-key-lst)
                                                    nextp
                                                    fail-k
                                                    (add-pat-var ctemp pvar-lst)
                                                    depth
                                                    cata-fun
                                                    (add-cata-def depth
                                                                  (syntax [cvar ...])
                                                                  (syntax cata)
                                                                  ctemp
                                                                  cata-defs)
                                                    dotted-vars)])
                     (values (with-syntax ([ax attr-exp]
                                           [ct ctemp]
                                           [body tests])
                               (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                         (let ([ct (if binding
                                                       (cadr binding)
                                                       default)])
                                           body))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [((atag [(unquote [cvar ...]) default]) . rst)
                 (identifier? (syntax atag))
                 (let ([ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (if (not cata-fun)
                       (sxml-match-syntax-error "sxml-match pattern: catamorphism not allowed in this context"
                                                stx
                                                (syntax [cvar ...])))
                   (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-attr-list (syntax rst)
                                                    body-lst
                                                    attr-exp
                                                    body-exp
                                                    (cons (syntax atag) attr-key-lst)
                                                    nextp
                                                    fail-k
                                                    (add-pat-var ctemp pvar-lst)
                                                    depth
                                                    cata-fun
                                                    (add-cata-def depth
                                                                  (syntax [cvar ...])
                                                                  cata-fun
                                                                  ctemp
                                                                  cata-defs)
                                                    dotted-vars)])
                     (values (with-syntax ([ax attr-exp]
                                           [ct ctemp]
                                           [body tests])
                               (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                         (let ([ct (if binding
                                                       (cadr binding)
                                                       default)])
                                           body))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [((atag [(unquote var) default]) . rst)
                 (and (identifier? (syntax atag)) (identifier? (syntax var)))
                 (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                               (compile-attr-list (syntax rst)
                                                  body-lst
                                                  attr-exp
                                                  body-exp
                                                  (cons (syntax atag) attr-key-lst)
                                                  nextp
                                                  fail-k
                                                  (add-pat-var (syntax var) pvar-lst)
                                                  depth
                                                  cata-fun
                                                  cata-defs
                                                  dotted-vars)])
                   (values (with-syntax ([ax attr-exp]
                                         [body tests])
                             (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                       (let ([var (if binding
                                                      (cadr binding)
                                                      default)])
                                         body))))
                           new-pvar-lst
                           new-cata-defs
                           new-dotted-vars))]
                [((atag (unquote [cata -> cvar ...])) . rst)
                 (identifier? (syntax atag))
                 (let ([ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-attr-list (syntax rst)
                                                    body-lst
                                                    attr-exp
                                                    body-exp
                                                    (cons (syntax atag) attr-key-lst)
                                                    nextp
                                                    fail-k
                                                    (add-pat-var ctemp pvar-lst)
                                                    depth
                                                    cata-fun
                                                    (add-cata-def depth
                                                                  (syntax [cvar ...])
                                                                  (syntax cata)
                                                                  ctemp
                                                                  cata-defs)
                                                    dotted-vars)])
                     (values (with-syntax ([ax attr-exp]
                                           [ct ctemp]
                                           [body tests]
                                           [fail-to fail-k])
                               (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                         (if binding
                                             (let ([ct (cadr binding)])
                                               body)
                                             (fail-to)))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [((atag (unquote [cvar ...])) . rst)
                 (identifier? (syntax atag))
                 (let ([ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (if (not cata-fun)
                       (sxml-match-syntax-error "sxml-match pattern: catamorphism not allowed in this context"
                                                stx
                                                (syntax [cvar ...])))
                   (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-attr-list (syntax rst)
                                                    body-lst
                                                    attr-exp
                                                    body-exp
                                                    (cons (syntax atag) attr-key-lst)
                                                    nextp
                                                    fail-k
                                                    (add-pat-var ctemp pvar-lst)
                                                    depth
                                                    cata-fun
                                                    (add-cata-def depth
                                                                  (syntax [cvar ...])
                                                                  cata-fun
                                                                  ctemp
                                                                  cata-defs)
                                                    dotted-vars)])
                     (values (with-syntax ([ax attr-exp]
                                           [ct ctemp]
                                           [body tests]
                                           [fail-to fail-k])
                               (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                         (if binding
                                             (let ([ct (cadr binding)])
                                               body)
                                             (fail-to)))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [((atag (unquote var)) . rst)
                 (and (identifier? (syntax atag)) (identifier? (syntax var)))
                 (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                               (compile-attr-list (syntax rst)
                                                  body-lst
                                                  attr-exp
                                                  body-exp
                                                  (cons (syntax atag) attr-key-lst)
                                                  nextp
                                                  fail-k
                                                  (add-pat-var (syntax var) pvar-lst)
                                                  depth
                                                  cata-fun
                                                  cata-defs
                                                  dotted-vars)])
                   (values (with-syntax ([ax attr-exp]
                                         [body tests]
                                         [fail-to fail-k])
                             (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                       (if binding
                                           (let ([var (cadr binding)])
                                             body)
                                           (fail-to)))))
                           new-pvar-lst
                           new-cata-defs
                           new-dotted-vars))]
                [((atag (i ...)) . rst)
                 (identifier? (syntax atag))
                 (sxml-match-syntax-error "bad attribute pattern"
                                          stx
                                          (syntax (kwd (i ...))))]
                [((atag i) . rst)
                 (and (identifier? (syntax atag)) (identifier? (syntax i)))
                 (sxml-match-syntax-error "bad attribute pattern"
                                          stx
                                          (syntax (kwd i)))]
                [((atag literal) . rst)
                 (and (identifier? (syntax atag)) (literal? (syntax literal)))
                 (let-values ([(tests new-pvar-lst new-cata-defs new-dotted-vars)
                               (compile-attr-list (syntax rst)
                                                  body-lst
                                                  attr-exp
                                                  body-exp
                                                  (cons (syntax atag) attr-key-lst)
                                                  nextp
                                                  fail-k
                                                  pvar-lst
                                                  depth
                                                  cata-fun
                                                  cata-defs
                                                  dotted-vars)])
                   (values (with-syntax ([ax attr-exp]
                                         [body tests]
                                         [fail-to fail-k])
                             (syntax (let ([binding (match-xml-attribute 'atag ax)])
                                       (if binding
                                           (if (equal? (cadr binding) literal)
                                               body
                                               (fail-to))
                                           (fail-to)))))
                           new-pvar-lst
                           new-cata-defs
                           new-dotted-vars))]
                [()
                 (compile-item-list body-lst
                                    body-exp
                                    nextp
                                    fail-k
                                    #t
                                    pvar-lst
                                    depth
                                    cata-fun
                                    cata-defs
                                    dotted-vars)]))]
           [compile-item-list
            (lambda (lst exp nextp fail-k ellipsis-allowed? pvar-lst depth cata-fun cata-defs dotted-vars)
              (syntax-case lst (unquote ->)
                [() (compile-end-element exp nextp fail-k pvar-lst cata-defs dotted-vars)]
                [(unquote var)
                 (identifier? (syntax var))
                 (if (not ellipsis-allowed?)
                     (sxml-match-syntax-error "improper list pattern not allowed in this context"
                                              stx
                                              (syntax dots))
                     (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                   (nextp (add-pat-var (syntax var) pvar-lst) cata-defs dotted-vars)])
                       (values (with-syntax ([x exp]
                                             [body next-tests])
                                 (syntax (let ([var x]) body)))
                               new-pvar-lst
                               new-cata-defs
                               new-dotted-vars)))]
                [(unquote [cata -> cvar ...])
                 (if (not ellipsis-allowed?)
                     (sxml-match-syntax-error "improper list pattern not allowed in this context"
                                              stx
                                              (syntax dots))
                     (let ([ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                       (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                     (nextp (add-pat-var ctemp pvar-lst)
                                            (add-cata-def depth
                                                          (syntax [cvar ...])
                                                          (syntax cata)
                                                          ctemp
                                                          cata-defs)
                                            dotted-vars)])
                         (values (with-syntax ([ct ctemp]
                                               [x exp]
                                               [body next-tests])
                                   (syntax (let ([ct x]) body)))
                                 new-pvar-lst
                                 new-cata-defs
                                 new-dotted-vars))))]
                [(unquote [cvar ...])
                 (let ([ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (if (not cata-fun)
                       (sxml-match-syntax-error "sxml-match pattern: catamorphism not allowed in this context"
                                                stx
                                                (syntax [cvar ...])))
                   (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (nextp (add-pat-var ctemp pvar-lst)
                                        (add-cata-def depth
                                                      (syntax [cvar ...])
                                                      cata-fun
                                                      ctemp
                                                      cata-defs)
                                        dotted-vars)])
                     (values (with-syntax ([ct ctemp]
                                           [x exp]
                                           [body next-tests])
                               (syntax (let ([ct x]) body)))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [(item dots . rst)
                 (ellipsis? (syntax dots))
                 (if (not ellipsis-allowed?)
                     (sxml-match-syntax-error "ellipses not allowed in this context"
                                              stx
                                              (syntax dots))
                     (compile-dotted-pattern-list (syntax item)
                                                  (syntax rst)
                                                  exp
                                                  nextp
                                                  fail-k
                                                  pvar-lst
                                                  depth
                                                  cata-fun
                                                  cata-defs
                                                  dotted-vars))]
                [(item . rst)
                 (compile-item (syntax item)
                               exp
                               (lambda (new-exp new-pvar-lst new-cata-defs new-dotted-vars)
                                 (compile-item-list (syntax rst)
                                                    new-exp
                                                    nextp
                                                    fail-k
                                                    ellipsis-allowed?
                                                    new-pvar-lst
                                                    depth
                                                    cata-fun
                                                    new-cata-defs
                                                    new-dotted-vars))
                               fail-k
                               pvar-lst
                               depth
                               cata-fun
                               cata-defs
                               dotted-vars)]))]
           [compile-dotted-pattern-list
            (lambda (item
                     tail
                     exp
                     nextp
                     fail-k
                     pvar-lst
                     depth
                     cata-fun
                     cata-defs
                     dotted-vars)
              (let-values ([(tail-tests tail-pvar-lst tail-cata-defs tail-dotted-vars)
                            (compile-item-list tail
                                               (syntax lst)
                                               (lambda (new-pvar-lst new-cata-defs new-dotted-vars)
                                                 (values (with-syntax ([(npv ...) new-pvar-lst])
                                                           (syntax (values #t npv ...)))
                                                         new-pvar-lst
                                                         new-cata-defs
                                                         new-dotted-vars))
                                               (syntax fail)
                                               #f
                                               '()
                                               depth
                                               '()
                                               '()
                                               dotted-vars)]
                           [(item-tests item-pvar-lst item-cata-defs item-dotted-vars)
                            (compile-item item
                                          (syntax lst)
                                          (lambda (new-exp new-pvar-lst new-cata-defs new-dotted-vars)
                                            (values (with-syntax ([(npv ...) new-pvar-lst])
                                                      (syntax (values #t (cdr lst) npv ...)))
                                                    new-pvar-lst
                                                    new-cata-defs
                                                    new-dotted-vars))
                                          (syntax fail)
                                          '()
                                          (+ 1 depth)
                                          cata-fun
                                          '()
                                          dotted-vars)])
                ; more here: check for duplicate pat-vars, cata-defs
                (let-values ([(final-tests final-pvar-lst final-cata-defs final-dotted-vars)
                              (nextp (append tail-pvar-lst item-pvar-lst pvar-lst)
                                     (append tail-cata-defs item-cata-defs cata-defs)
                                     (append item-pvar-lst
                                             (cata-defs->pvar-lst item-cata-defs)
                                             tail-dotted-vars
                                             dotted-vars))])
                  (let ([temp-item-pvar-lst (generate-temporaries item-pvar-lst)])
                    (values
                     (with-syntax
                         ([x exp]
                          [fail-to fail-k]
                          [tail-body tail-tests]
                          [item-body item-tests]
                          [final-body final-tests]
                          [(ipv ...) item-pvar-lst]
                          [(gpv ...) temp-item-pvar-lst]
                          [(tpv ...) tail-pvar-lst]
                          [(item-void ...) (map (lambda (i) (syntax (void))) item-pvar-lst)]
                          [(tail-void ...) (map (lambda (i) (syntax (void))) tail-pvar-lst)]
                          [(item-null ...) (map (lambda (i) (syntax '())) item-pvar-lst)]
                          [(item-cons ...) (map (lambda (a b)
                                                  (with-syntax ([xa a]
                                                                [xb b])
                                                    (syntax (cons xa xb))))
                                                item-pvar-lst
                                                temp-item-pvar-lst)])
                       (syntax (letrec ([match-tail
                                         (lambda (lst fail)
                                           tail-body)]
                                        [match-item
                                         (lambda (lst)
                                           (let ([fail (lambda ()
                                                         (values #f
                                                                 lst
                                                                 item-void ...))])
                                             item-body))]
                                        [match-dotted
                                         (lambda (x)
                                           (let-values ([(tail-res tpv ...)
                                                         (match-tail x
                                                                     (lambda ()
                                                                       (values #f
                                                                               tail-void ...)))])
                                             (if tail-res
                                                 (values item-null ...
                                                         tpv ...)
                                                 (let-values ([(res new-x ipv ...) (match-item x)])
                                                   (if res
                                                       (let-values ([(gpv ... tpv ...)
                                                                     (match-dotted new-x)])
                                                         (values item-cons ... tpv ...))
                                                       (let-values ([(last-tail-res tpv ...)
                                                                     (match-tail x fail-to)])
                                                         (values item-null ... tpv ...)))))))])
                                 (let-values ([(ipv ... tpv ...)
                                               (match-dotted x)])
                                   final-body))))
                     final-pvar-lst
                     final-cata-defs
                     final-dotted-vars)))))]
           [compile-item
            (lambda (item exp nextp fail-k pvar-lst depth cata-fun cata-defs dotted-vars)
              (syntax-case item (unquote ->)
                ; normal pattern var
                [(unquote var)
                 (identifier? (syntax var))
                 (let ([new-exp (car (generate-temporaries (list exp)))])
                   (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (nextp new-exp (add-pat-var (syntax var) pvar-lst) cata-defs dotted-vars)])
                     (values (with-syntax ([x exp]
                                           [nx new-exp]
                                           [body next-tests]
                                           [fail-to fail-k])
                               (syntax (if (pair? x)
                                           (let ([nx (cdr x)]
                                                 [var (car x)])
                                             body)
                                           (fail-to))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                ; named catamorphism
                [(unquote [cata -> cvar ...])
                 (let ([new-exp (car (generate-temporaries (list exp)))]
                       [ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (nextp new-exp
                                        (add-pat-var ctemp pvar-lst)
                                        (add-cata-def depth
                                                      (syntax [cvar ...])
                                                      (syntax cata)
                                                      ctemp
                                                      cata-defs)
                                        dotted-vars)])
                     (values (with-syntax ([x exp]
                                           [nx new-exp]
                                           [ct ctemp]
                                           [body next-tests]
                                           [fail-to fail-k])
                               (syntax (if (pair? x)
                                           (let ([nx (cdr x)]
                                                 [ct (car x)])
                                             body)
                                           (fail-to))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                ; basic catamorphism
                [(unquote [cvar ...])
                 (let ([new-exp (car (generate-temporaries (list exp)))]
                       [ctemp (car (generate-temporaries (syntax ([cvar ...]))))])
                   (if (not cata-fun)
                       (sxml-match-syntax-error "sxml-match pattern: catamorphism not allowed in this context"
                                                stx
                                                (syntax [cvar ...])))
                   (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (nextp new-exp
                                        (add-pat-var ctemp pvar-lst)
                                        (add-cata-def depth
                                                      (syntax [cvar ...])
                                                      cata-fun
                                                      ctemp
                                                      cata-defs)
                                        dotted-vars)])
                     (values (with-syntax ([x exp]
                                           [nx new-exp]
                                           [ct ctemp]
                                           [body next-tests]
                                           [fail-to fail-k])
                               (syntax (if (pair? x)
                                           (let ([nx (cdr x)]
                                                 [ct (car x)])
                                             body)
                                           (fail-to))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]
                [(tag item ...)
                 (identifier? (syntax tag))
                 (let ([new-exp (car (generate-temporaries (list exp)))])
                   (let-values ([(after-tests after-pvar-lst after-cata-defs after-dotted-vars)
                                 (compile-element-pat (syntax (tag item ...))
                                                      (with-syntax ([x exp])
                                                        (syntax (car x)))
                                                      (lambda (more-pvar-lst more-cata-defs more-dotted-vars)
                                                        (let-values ([(next-tests new-pvar-lst
                                                                                  new-cata-defs
                                                                                  new-dotted-vars)
                                                                      (nextp new-exp
                                                                             more-pvar-lst
                                                                             more-cata-defs
                                                                             more-dotted-vars)])
                                                          (values (with-syntax ([x exp]
                                                                                [nx new-exp]
                                                                                [body next-tests])
                                                                    (syntax (let ([nx (cdr x)])
                                                                              body)))
                                                                  new-pvar-lst
                                                                  new-cata-defs
                                                                  new-dotted-vars)))
                                                      fail-k
                                                      pvar-lst
                                                      depth
                                                      cata-fun
                                                      cata-defs
                                                      dotted-vars)])
                     ; test that we are not at the end of an item-list, BEFORE
                     ; entering tests for the element pattern (against the 'car' of the item-list)
                     (values (with-syntax ([x exp]
                                           [body after-tests]
                                           [fail-to fail-k])
                               (syntax (if (pair? x)
                                           body
                                           (fail-to))))
                             after-pvar-lst
                             after-cata-defs
                             after-dotted-vars)))]
                [(i ...)
                 (sxml-match-syntax-error "bad pattern syntax (not an element pattern)"
                                          stx
                                          (syntax (i ...)))]
                [i
                 (identifier? (syntax i))
                 (sxml-match-syntax-error "bad pattern syntax (symbol not allowed in this context)"
                                          stx
                                          (syntax i))]
                [literal
                 (literal? (syntax literal))
                 (let ([new-exp (car (generate-temporaries (list exp)))])
                   (let-values ([(next-tests new-pvar-lst new-cata-defs new-dotted-vars)
                                 (nextp new-exp pvar-lst cata-defs dotted-vars)])
                     (values (with-syntax ([x exp]
                                           [nx new-exp]
                                           [body next-tests]
                                           [fail-to fail-k])
                               (syntax (if (and (pair? x) (equal? literal (car x)))
                                           (let ([nx (cdr x)])
                                             body)
                                           (fail-to))))
                             new-pvar-lst
                             new-cata-defs
                             new-dotted-vars)))]))])
        (let ([fail-k (syntax failure)])
          (syntax-case stx (unquote guard ->)
            [(compile-clause ((unquote var) (guard gexp ...) action0 action ...)
                             exp
                             cata-fun
                             fail-exp)
             (identifier? (syntax var))
             (syntax (let ([var exp])
                       (if (and gexp ...)
                           (begin action0 action ...)
                           (fail-exp))))]
            [(compile-clause ((unquote [cata -> cvar ...]) (guard gexp ...) action0 action ...)
                             exp
                             cata-fun
                             fail-exp)
             (syntax (if (and gexp ...)
                         (let-values ([(cvar ...) (cata exp)])
                           (begin action0 action ...))
                         (fail-exp)))]
            [(compile-clause ((unquote [cvar ...]) (guard gexp ...) action0 action ...)
                             exp
                             cata-fun
                             fail-exp)
             (if (not (extract-cata-fun (syntax cata-fun)))
                 (sxml-match-syntax-error "sxml-match pattern: catamorphism not allowed in this context"
                                          stx
                                          (syntax [cvar ...]))
                 (syntax (if (and gexp ...)
                             (let-values ([(cvar ...) (cata-fun exp)])
                               (begin action0 action ...))
                             (fail-exp))))]
            [(compile-clause ((unquote var) action0 action ...) exp cata-fun fail-exp)
             (identifier? (syntax var))
             (syntax (let ([var exp])
                       action0 action ...))]
            [(compile-clause ((unquote [cata -> cvar ...]) action0 action ...) exp cata-fun fail-exp)
             (syntax (let-values ([(cvar ...) (cata exp)])
                       action0 action ...))]
            [(compile-clause ((unquote [cvar ...]) action0 action ...) exp cata-fun fail-exp)
             (if (not (extract-cata-fun (syntax cata-fun)))
                 (sxml-match-syntax-error "sxml-match pattern: catamorphism not allowed in this context"
                                          stx
                                          (syntax [cvar ...]))
                 (syntax (let-values ([(cvar ...) (cata-fun exp)])
                           action0 action ...)))]
            [(compile-clause ((lst . rst) (guard gexp ...) action0 action ...) exp cata-fun fail-exp)
             (and (identifier? (syntax lst)) (eq? 'list (syntax-object->datum (syntax lst))))
             (let-values ([(result pvar-lst cata-defs dotted-vars)
                           (compile-item-list (syntax rst)
                                              (syntax exp)
                                              (lambda (new-pvar-lst new-cata-defs new-dotted-vars)
                                                (values
                                                 (with-syntax
                                                     ([exp-body (process-cata-defs new-cata-defs
                                                                                   (process-output-action
                                                                                    (syntax (begin action0
                                                                                                   action ...))
                                                                                    new-dotted-vars))]
                                                      [fail-to fail-k])
                                                   (syntax (if (and gexp ...) exp-body (fail-to))))
                                                 new-pvar-lst
                                                 new-cata-defs
                                                 new-dotted-vars))
                                              fail-k
                                              #t
                                              '()
                                              0
                                              (extract-cata-fun (syntax cata-fun))
                                              '()
                                              '())])
               (with-syntax ([fail-to fail-k]
                             [body result])
                 (syntax (let ([fail-to fail-exp])
                           (if (nodeset? exp)
                               body
                               (fail-to))))))]
            [(compile-clause ((lst . rst) action0 action ...) exp cata-fun fail-exp)
             (and (identifier? (syntax lst)) (eq? 'list (syntax-object->datum (syntax lst))))
             (let-values ([(result pvar-lst cata-defs dotted-vars)
                           (compile-item-list (syntax rst)
                                              (syntax exp)
                                              (lambda (new-pvar-lst new-cata-defs new-dotted-vars)
                                                (values (process-cata-defs new-cata-defs
                                                                           (process-output-action
                                                                            (syntax (begin action0
                                                                                           action ...))
                                                                            new-dotted-vars))
                                                        new-pvar-lst
                                                        new-cata-defs
                                                        new-dotted-vars))
                                              fail-k
                                              #t
                                              '()
                                              0
                                              (extract-cata-fun (syntax cata-fun))
                                              '()
                                              '())])
               (with-syntax ([body result]
                             [fail-to fail-k])
                 (syntax (let ([fail-to fail-exp])
                           (if (nodeset? exp)
                               body
                               (fail-to))))))]
            [(compile-clause ((fst . rst) (guard gexp ...) action0 action ...) exp cata-fun fail-exp)
             (identifier? (syntax fst))
             (let-values ([(result pvar-lst cata-defs dotted-vars)
                           (compile-element-pat (syntax (fst . rst))
                                                (syntax exp)
                                                (lambda (new-pvar-lst new-cata-defs new-dotted-vars)
                                                  (values
                                                   (with-syntax
                                                       ([body (process-cata-defs new-cata-defs
                                                                                 (process-output-action
                                                                                  (syntax (begin action0
                                                                                                 action ...))
                                                                                  new-dotted-vars))]
                                                        [fail-to fail-k])
                                                     (syntax (if (and gexp ...) body (fail-to))))
                                                   new-pvar-lst
                                                   new-cata-defs
                                                   new-dotted-vars))
                                                fail-k
                                                '()
                                                0
                                                (extract-cata-fun (syntax cata-fun))
                                                '()
                                                '())])
               (with-syntax ([fail-to fail-k]
                             [body result])
                 (syntax (let ([fail-to fail-exp])
                           body))))]
            [(compile-clause ((fst . rst) action0 action ...) exp cata-fun fail-exp)
             (identifier? (syntax fst))
             (let-values ([(result pvar-lst cata-defs dotted-vars)
                           (compile-element-pat (syntax (fst . rst))
                                                (syntax exp)
                                                (lambda (new-pvar-lst new-cata-defs new-dotted-vars)
                                                  (values (process-cata-defs new-cata-defs
                                                                             (process-output-action
                                                                              (syntax (begin action0
                                                                                             action ...))
                                                                              new-dotted-vars))
                                                          new-pvar-lst
                                                          new-cata-defs
                                                          new-dotted-vars))
                                                fail-k
                                                '()
                                                0
                                                (extract-cata-fun (syntax cata-fun))
                                                '()
                                                '())])
               (with-syntax ([fail-to fail-k]
                             [body result])
                 (syntax (let ([fail-to fail-exp])
                           body))))]
            [(compile-clause ((i ...) (guard gexp ...) action0 action ...) exp cata-fun fail-exp)
             (sxml-match-syntax-error "bad pattern syntax (not an element pattern)"
                                      stx
                                      (syntax (i ...)))]
            [(compile-clause ((i ...) action0 action ...) exp cata-fun fail-exp)
             (sxml-match-syntax-error "bad pattern syntax (not an element pattern)"
                                      stx
                                      (syntax (i ...)))]
            [(compile-clause (pat (guard gexp ...) action0 action ...) exp cata-fun fail-exp)
             (identifier? (syntax pat))
             (sxml-match-syntax-error "bad pattern syntax (symbol not allowed in this context)"
                                      stx
                                      (syntax pat))]
            [(compile-clause (pat action0 action ...) exp cata-fun fail-exp)
             (identifier? (syntax pat))
             (sxml-match-syntax-error "bad pattern syntax (symbol not allowed in this context)"
                                      stx
                                      (syntax pat))]
            [(compile-clause (literal (guard gexp ...) action0 action ...) exp cata-fun fail-exp)
             (literal? (syntax literal))
             (syntax (if (and (equal? literal exp) (and gexp ...))
                         (begin action0 action ...)
                         (fail-exp)))]
            [(compile-clause (literal action0 action ...) exp cata-fun fail-exp)
             (literal? (syntax literal))
             (syntax (if (equal? literal exp)
                         (begin action0 action ...)
                         (fail-exp)))])))))
  
  )

(module matcher-helper (sxml-match1)
  
  (import portability)
  (import internal-compile-clause)
  
  (define-syntax sxml-match1
    (syntax-rules ()
      [(sxml-match1 exp cata-fun clause)
       (compile-clause clause exp cata-fun
                       (lambda () (error 'sxml-match "no matching clause found")))]
      [(sxml-match1 exp cata-fun clause0 clause ...)
       (let/ec escape
         (compile-clause clause0 exp cata-fun
                         (lambda () (escape (sxml-match1 exp cata-fun clause ...)))))]))
  )

(module match-let-meta-helper (sxml-match-let1)
  
  (import internal-compile-clause)
  
  (define-syntax sxml-match-let1
    (syntax-rules ()
      [(sxml-match-let1 syntag synform () body0 body ...)
       (let () body0 body ...)]
      [(sxml-match-let1 syntag synform ([pat exp]) body0 body ...)
       (compile-clause (pat (let () body0 body ...))
                       exp
                       #f
                       (lambda () (error 'syntag "could not match pattern ~s" 'pat)))]
      [(sxml-match-let1 syntag synform ([pat0 exp0] [pat exp] ...) body0 body ...)
       (compile-clause (pat0 (sxml-match-let1 syntag synform ([pat exp] ...) body0 body ...))
                       exp0
                       #f
                       (lambda () (error 'syntag "could not match pattern ~s" 'pat0)))]))
  
  )

(module match-let-helper (sxml-match-let-help)
  
  (import match-let-meta-helper)
  
  (define-syntax sxml-match-let-help
    (lambda (stx)
      (syntax-case stx ()
        [(sxml-match-let-help syntag synform ([pat exp] ...) body0 body ...)
         (with-syntax ([(temp-name ...) (generate-temporaries (syntax (exp ...)))])
           (syntax (let ([temp-name exp] ...)
                     (sxml-match-let1 syntag synform ([pat temp-name] ...) body0 body ...))))])))
  
  )

(module sxml-matcher (sxml-match sxml-match-let sxml-match-let*)
  
  (import matcher-helper)
  (import match-let-helper)
  
  (define-syntax sxml-match
    (syntax-rules ()
      ((sxml-match val clause0 clause ...)
       (letrec ([cfun (lambda (exp)
                        (sxml-match1 exp cfun clause0 clause ...))])
         (cfun val)))))
  
  (define-syntax sxml-match-let
    (lambda (stx)
      (syntax-case stx ()
        [(sxml-match-let ([pat exp] ...) body0 body ...)
         (with-syntax ([synform stx])
           (syntax (sxml-match-let-help sxml-match-let synform ([pat exp] ...) body0 body ...)))])))
  
  (define-syntax sxml-match-let*
    (lambda (stx)
      (syntax-case stx ()
        [(sxml-match-let* () body0 body ...)
         (syntax (let () body0 body ...))]
        [(sxml-match-let* ([pat0 exp0] [pat exp] ...) body0 body ...)
         (with-syntax ([synform stx])
           (syntax (sxml-match-let-help sxml-match-let* synform ([pat0 exp0])
                                        (sxml-match-let* ([pat exp] ...)
                                          body0 body ...))))])))
  
  )

