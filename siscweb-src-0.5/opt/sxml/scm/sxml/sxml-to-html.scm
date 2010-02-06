;			HTML Authoring in SXML
;
; The present file defines and demonstrates a function SXML->HTML, the
; most generic transformation of SXML into the corresponding HTML
; document. The SXML tree is traversed post-order and converted into
; another tree, which, written in a depth-first fashion, results in a
; HTML document. The function SXML->HTML can generate an arbitrary
; HTML markup, for any existing or yet to be introduced HTML
; tag. Furthermore, the function supports one higher-level tag,
; 'html:begin'. As the source code below indicates, SXML->HTML can be
; trivially extended to support other higher-level tags.
;
; The proper HTML markup is being created by a set of node
; handlers. An iterator 'post-order' executes these functions while it
; traverses an SXML tree.
;
; Each node handler takes a tag (the head of an SXML node) and the
; list of children nodes, if any. A handler returns a fragment or a
; list of HTML fragments -- which become arguments to a handler of a
; parent SXML node.  A function SRV:send-reply takes the resulting
; tree of fragments and writes out the fragments in a depth-first
; order. The output is an HTML document that corresponds to the
; original SXML tree.
;
; This pretty-printing operation  makes it possible to author and
; compose HTML documents in their SXML form. SXML is more concise and
; expressive than a raw markup language. SXML representing regular
; Scheme code can be entered in any Scheme-sensitive editor. SXML as a
; data structure -- a list -- can likewise be composed as a literal or
; quasi-literal expression. Furthermore, SXML can be produced by regular
; Scheme functions, which may make authoring more succinct, advanced,
; and less tedious, as the code below illustrates.
;
; IMPORT
; A prelude appropriate for your Scheme system
;	(myenv-bigloo.scm, myenv-mit.scm, etc.)
; util.scm for make-char-quotator
; SXML-tree-trans.scm for post-order
;
; EXPORT
; SXML->HTML enattr entag string->goodHTML
;
; All these files are available in the same directory as this file.
; See vSXML-to-HTML.scm for the validation code, which also
; serves as usage examples.
;
; See http://pobox.com/~oleg/ftp/Scheme/xml.html#XML-authoring
; for more examples and explanation.
;
; $Id: sxml-to-html.scm,v 1.2 2005/11/25 20:46:38 acolomba Exp $


; The following procedure is the most generic transformation of SXML
; into the corresponding HTML document. The SXML tree is traversed
; post-oder (depth-first) and transformed into another tree, which,
; written in a depth-first fashion, results in an HTML document.

(define (SXML->HTML tree)
 (SRV:send-reply
   (pre-post-order tree
                ; Universal transformation rules. Work for every HTML,
                ; present and future
    `((@
      ((*default*       ; local override for attributes
        . ,(lambda (attr-key . value) (enattr attr-key value))))
      . ,(lambda (trigger . value) (cons '@ value)))
     (*default* . ,(lambda (tag . elems) (entag tag elems)))
     (*text* . ,(lambda (trigger str)
		  (if (string? str) (string->goodHTML str) str)))

                ; Handle a nontraditional but convenient top-level element:
                ; (html:begin title <html-body>) element
     (html:begin . ,(lambda (tag title . elems)
        (list "Content-type: text/html"         ; HTTP headers
              nl nl                            ; two nl end the headers
              "<HTML><HEAD><TITLE>" title "</TITLE></HEAD>"
	      elems
              "</HTML>"))))

     )))

; The following two functions create the HTML markup for tags and attributes.
; They are being used in the node handlers for the post-order function, see
; above.

(define (entag tag elems)
  (if (and (pair? elems) (pair? (car elems)) (eq? '@ (caar elems)))
    (list #\< tag (cdar elems) #\>
      (and (pair? (cdr elems))
	(list (cdr elems) "</" tag #\>)))
    (list #\newline #\< tag #\> (and (pair? elems) (list elems "</" tag #\>))
      )))

(define (enattr attr-key value)
  (if (null? value) (list #\space attr-key)
    (list #\space attr-key "=\"" value #\")))



; make-char-quotator QUOT-RULES
;
; Given QUOT-RULES, an assoc list of (char . string) pairs, return
; a quotation procedure. The returned quotation procedure takes a string
; and returns either a string or a list of strings. The quotation procedure
; check to see if its argument string contains any instance of a character
; that needs to be encoded (quoted). If the argument string is "clean",
; it is returned unchanged. Otherwise, the quotation procedure will
; return a list of string fragments. The input straing will be broken
; at the places where the special characters occur. The special character
; will be replaced by the corresponding encoding strings.
;
; For example, to make a procedure that quotes special HTML characters,
; do
;	(make-char-quotator
;	    '((#\< . "&lt;") (#\> . "&gt;") (#\& . "&amp;") (#\" . "&quot;")))

(define (make-char-quotator char-encoding)
  (let ((bad-chars (map car char-encoding)))

    ; Check to see if str contains one of the characters in charset,
    ; from the position i onward. If so, return that character's index.
    ; otherwise, return #f
    (define (index-cset str i charset)
      (let loop ((i i))
	(and (< i (string-length str))
	     (if (memv (string-ref str i) charset) i
		 (loop (+ 1 i))))))

    ; The body of the function
    (lambda (str)
      (let ((bad-pos (index-cset str 0 bad-chars)))
	(if (not bad-pos) str	; str had all good chars
	    (let loop ((from 0) (to bad-pos))
	      (cond
	       ((>= from (string-length str)) '())
	       ((not to)
		(cons (substring str from (string-length str)) '()))
	       (else
		(let ((quoted-char
		       (cdr (assv (string-ref str to) char-encoding)))
		      (new-to
		       (index-cset str (+ 1 to) bad-chars)))
		  (if (< from to)
		      (cons
		       (substring str from to)
		       (cons quoted-char (loop (+ 1 to) new-to)))
		      (cons quoted-char (loop (+ 1 to) new-to))))))))))
))


; Given a string, check to make sure it does not contain characters
; such as '<' or '&' that require encoding. Return either the original
; string, or a list of string fragments with special characters
; replaced by appropriate character entities.

(define string->goodHTML
  (make-char-quotator
   '((#\< . "&lt;") (#\> . "&gt;") (#\& . "&amp;") (#\" . "&quot;"))))
