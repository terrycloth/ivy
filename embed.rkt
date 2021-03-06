#lang racket/base
; embed.rkt
; embed tags into images that support it
(require file/gunzip
         file/gzip
         gif-image
         ; identifier conflict with xml
         (prefix-in gif: gif-image/gif-basics)
         png-image
         racket/contract
         racket/date
         racket/file
         racket/format
         racket/list
         racket/port
         riff
         txexpr
         xml
         (only-in "files.rkt" ivy-version))
(provide add-embed-tags!
         dc:subject->list
         del-embed-tags!
         embed-support?
         get-embed-tags
         get-embed-xmp
         is-dc:subject?
         is-rdf:Description?
         is-rdf:li?
         is-tag?
         make-xmp-xexpr
         rdf:li-fixer
         set-embed-tags!
         set-embed-xmp!
         set-xmp-tag
         xexpr->xmp
         xmp-rating)

#|
xmp packet comments
#"<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
payload goes here
#"<?xpacket end=\"w\"?>"

PNG XMP keyword: #"XML:com.adobe.xmp"
JPEG XMP keyword: #"http://ns.adobe.com/xap/1.0/\0"
GIF XMP keyword: #"XMP Data" with auth #"XMP"
|#

; jpeg XMP string
(define jpeg-XMP-id #"http://ns.adobe.com/xap/1.0/\0")
(define SOI #xd8)
(define APP1 #xe1)
(define EOI #xd9)

; GIF XMP stuff
(define gif-XMP-id #"XMP Data")
(define gif-XMP-auth #"XMP")
(define gif-XMP-header (bytes-append gif-XMP-id gif-XMP-auth))

#|     JPEG stuff     |#

(define (jpeg-xmp? bstr)
  (and (>= (bytes-length bstr) (+ (bytes-length jpeg-XMP-id) 4))
       (bytes=? (subbytes bstr 4 (+ (bytes-length jpeg-XMP-id) 4)) jpeg-XMP-id)))

(define (jpeg-has-marker? in marker-byte)
  (and (regexp-try-match (byte-regexp (bytes #xff marker-byte)) in)
       #t))

; path-string, bytes, or input port
(define/contract (jpeg? img)
  (any/c . -> . boolean?)
  (cond [(path-string? img)
         (define img-in (open-input-file img))
         (define byts (peek-bytes 2 0 img-in))
         (close-input-port img-in)
         (bytes=? byts (bytes #xff SOI))]
        [(bytes? img)
         (define byts (subbytes img 0 2))
         (bytes=? byts (bytes #xff SOI))]
        [(input-port? img)
         (bytes=? (peek-bytes 2 0 img) (bytes #xff SOI))]
        [else #f]))

; returns a list of position pairs
(define/contract (jpeg-goto-marker in marker-byte)
  (jpeg? byte? . -> . (or/c (listof pair?) empty?))
  (regexp-match-peek-positions* (byte-regexp (bytes #xff marker-byte)) in))

; returns a list of APP1 bytes
(define/contract (jpeg-get-app1 img)
  (jpeg? . -> . (listof bytes?))
  (define img-in
    (cond [(bytes? img) (open-input-bytes img)]
          [(path-string? img) (open-input-file img)]
          [else img]))
  (define positions (jpeg-goto-marker img-in APP1))
  (define app1
    (for/list ([pair (in-list positions)])
      (define bstr (peek-bytes 2 (cdr pair) img-in))
      (define len (+ (integer-bytes->integer bstr #f #t) 2))
      (peek-bytes len (car pair) img-in)))
  ; only close the port if we made it inside this procedure
  (unless (input-port? img)
    (close-input-port img-in))
  app1)

#|     GIF stuff     |#

(define (read-gif x)
  (cond [(bytes? x) x]
        [(path-string? x)
         (call-with-input-file x (lambda (in) (read-bytes (file-size x) in)))]
        [else (error "read-gif: invalid input:" x)]))

(define (get-appn-pos x)
  (define data (read-gif x))
  (let loop ([n 0]
             [lst '()])
    (cond [(gif:trailer? data n) lst]
          [(gif:img? data n)
           (loop (+ n (gif:img-size data n)) lst)]
          [(gif:gce? data n)
           (loop (+ n (gif:gce-size data n)) lst)]
          [(gif:appn? data n)
           (define size (gif:appn-size data n))
           (loop (+ n size) (cons (list n size) lst))]
          [(gif:comment? data n)
           (loop (+ n (gif:comment-size data n)) lst)]
          [(gif:plain-text? data n)
           (loop (+ n (gif:plain-text-size data n)) lst)]
          [(gif:header? data n)
           (loop (+ n (gif:header-size data)) lst)]
          [else (loop (+ n 1) lst)])))

(define (gif-get-appn x)
  (define data (read-gif x))
  (define appn-lst (get-appn-pos data))
  (for/list ([appn (in-list appn-lst)])
    (define pos (first appn))
    (define len (second appn))
    (subbytes data pos (+ pos len))))

; takes the appn byte string and determines if it's XMP
(define (gif-appn-xmp? bstr)
  (bytes=? (subbytes bstr 3 (+ (bytes-length gif-XMP-header) 3))
           gif-XMP-header))

; generate appn byte string, ready to be inserted into the image
(define (make-xmp-appn bstr)
  (bytes-append
   ; gif extension number + application extension label
   (bytes #x21 #xff)
   ; length of header + auth
   (bytes (bytes-length gif-XMP-header))
   gif-XMP-header
   bstr
   (bytes 1)
   (apply bytes
          (for/list ([magic (in-range #xff #x00 -1)]) magic))
   (bytes 0 0)))

#|     SVG stuff     |#

(define (svg? img)
  (define header #"<?xml version")
  (define in (open-input-file img))
  (define type (read-bytes in (bytes-length header)))
  (close-input-port in)
  (bytes=? header type))

(define (svg-has-tag? in bstr)
  (and (regexp-try-match (byte-regexp bstr) in) #t))

#|     FLIF stuff     |#

(define (flif-has-marker? in marker-bytes)
  (and (regexp-try-match (byte-regexp marker-bytes) in) #t))

(define (flif-goto-marker in marker-bytes)
  (regexp-match-peek-positions (byte-regexp marker-bytes) in))

; seek until just after the header information and
; take into account the possible nb_frames varint
(define (flif-skip-header bstr)
  ; start at 6: FLIF + info + bpc
  (let loop ([pos 6]
             [section 0])
    (cond [(= section 3) pos]
          [(= section 2)
           (cond [(flif-animated? bstr)
                  ; count nb_frames
                  (define byte (bytes-ref bstr pos))
                  (if (< byte flif-separator)
                      (loop (+ pos 1) (+ section 1))
                      (loop (+ pos 1) section))]
                 [else (loop pos (+ section 1))])]
          [else
           ; scan through width+height
           (define byte (bytes-ref bstr pos))
           (if (< byte flif-separator)
               (loop (+ pos 1) (+ section 1))
               (loop (+ pos 1) section))])))

; 128
(define flif-separator #x80)

; see https://github.com/FLIF-hub/FLIF/blob/master/src/flif-enc.cpp#L747-L758
; for implementation details
(define (length->bytes num)
  (let loop ([number num]
             [done? #t])
    (cond [(< number flif-separator)
           (if done?
               (bytes number)
               (bytes (+ number flif-separator)))]
          [else
           (define lsb (bitwise-and number (- flif-separator 1)))
           (define n (arithmetic-shift number -7))
           (bytes-append
            (loop n #f)
            (loop lsb #t))])))

; modified from riff
(define (bytes->length bstr)
  (for/fold ([result 0])
            ([byte (in-bytes bstr)])
    (if (< byte flif-separator)
        (+ result byte)
        (arithmetic-shift (+ result (- byte flif-separator)) 7))))

#|     Embedding stuff     |#

(define/contract (embed-support? img)
  (any/c . -> . boolean?)
  (or (flif? img) (gif? img) (jpeg? img) (png? img) (svg? img)))

(define/contract (add-embed-tags! img taglist)
  (embed-support? list? . -> . void?)
  (cond [(flif? img) (add-embed-flif! img taglist)]
        [(gif? img) (add-embed-gif! img taglist)]
        [(jpeg? img) (add-embed-jpeg! img taglist)]
        [(png? img) (add-embed-png! img taglist)]
        [(svg? img) (add-embed-svg! img taglist)]))

; adds the taglist to the existing tags
(define (add-embed-flif! flif taglist)
  (define old-tags (get-embed-tags flif))
  (define reconciled (remove-duplicates (append old-tags taglist)))
  (set-embed-flif! flif reconciled))

; adds taglist to the existing tags
; if there are no existing tags, set them
(define (add-embed-png! png taglist)
  (define png-hash (png->hash png))
  ; grab the old XMP data as an XEXPR
  (define old-xmp (get-embed-png png-hash))
  (define old-tags (get-embed-tags png))
  (define reconciled (remove-duplicates (append old-tags taglist)))
  (define xexpr (if (empty? old-xmp)
                    ; if the image has no XMP data, generate some
                    (make-xmp-xexpr taglist)
                    (set-dc:subject (string->xexpr (first old-xmp)) reconciled)))
  (define str (xexpr->xmp xexpr))
  (define itxt-bstr (make-itxt-chunk "XML:com.adobe.xmp" str))
  (define itxt-hash (make-itxt-hash itxt-bstr))
  (define new-hash (itxt-set png-hash itxt-hash "XML:com.adobe.xmp"))
  (define new-png (hash->png new-hash))
  (call-with-atomic-output-file png (λ (out tmp-png) (void (write-bytes new-png out)))))

(define (add-embed-jpeg! jpeg taglist)
  (define jpeg-bytes (if (bytes? jpeg)
                         jpeg
                         (file->bytes jpeg)))
  ; only one XMP block allowed in a jpeg file
  (define old-lst (get-embed-tags jpeg-bytes))
  (set-embed-jpeg! jpeg (remove-duplicates (append taglist old-lst))))

(define (add-embed-gif! gif taglist)
  (define bstr (read-gif gif))
  (define old-lst (get-embed-tags bstr))
  (set-embed-gif! gif (remove-duplicates (append taglist old-lst))))

(define (add-embed-svg! svg taglist)
  (define bstr (if (bytes? svg)
                   svg
                   (file->bytes svg)))
  (define old-lst (get-embed-tags bstr))
  (set-embed-svg! svg (remove-duplicates (append taglist old-lst))))

(define/contract (set-embed-tags! img taglist)
  (embed-support? list? . -> . void?)
  (cond [(flif? img) (set-embed-flif! img taglist)]
        [(gif? img) (set-embed-gif! img taglist)]
        [(jpeg? img) (set-embed-jpeg! img taglist)]
        [(png? img) (set-embed-png! img taglist)]
        [(svg? img) (set-embed-svg! img taglist)]))

(define/contract (set-embed-xmp! img xmp-str)
  (embed-support? string? . -> . void?)
  (cond [(flif? img) (set-xmp-flif! img xmp-str)]
        [(gif? img) (set-xmp-gif! img xmp-str)]
        [(jpeg? img) (set-xmp-jpeg! img xmp-str)]
        [(png? img) (set-xmp-png! img xmp-str)]
        [(svg? img) (set-xmp-svg! img xmp-str)]))

; do not re-encode the file every time we modify the xmp
(define (set-xmp-flif! flif xmp)
  (define flif-bstr (file->bytes flif))
  (define flif-in (open-input-bytes flif-bstr))
  ; deflate the xmp metadata
  (define xmp-bstr (if (bytes? xmp) xmp (string->bytes/utf-8 xmp)))
  (define deflated-in (open-input-bytes xmp-bstr))
  (define deflated-out (open-output-bytes))
  (deflate deflated-in deflated-out)
  ; add checksum
  (define deflated-bstr
    (bytes-append (get-output-bytes deflated-out)
                  (integer->integer-bytes (bytes-adler32 xmp-bstr) 4 #f #t)))
  ; piece everything together
  (define has-exmp? (flif-goto-marker flif-in #"eXmp"))
  (define marker-lst
    (cond [has-exmp? has-exmp?]
          [else
           (define header (flif-skip-header flif-bstr))
           (list (cons header (+ header 1)))]))
  (close-input-port flif-in)
  (define marker (first marker-lst))
  ; just before #"eXmp"
  (define before (subbytes flif-bstr 0 (car marker)))
  (define len-bstr
    (if has-exmp?
        (let loop ([bstr #""]
                   [pos (cdr marker)])
          (define byte (bytes-ref flif-bstr pos))
          (if (< byte flif-separator)
              (bytes-append bstr (bytes byte))
              (loop (bytes-append bstr (bytes byte)) (+ pos 1))))
        #""))
  (define len (bytes->length len-bstr))
  ; skip up to len for after-bytes
  ; (if there is no existing eXmp chunk, seek until just after the header)
  (define after (subbytes flif-bstr (+ (if (zero? len)
                                           (car marker)
                                           (cdr marker))
                                       len
                                       (bytes-length len-bstr))))
  (call-with-atomic-output-file
   flif
   (λ (out tmp-flif)
     (fprintf out
              "~a~a~a~a~a"
              before
              #"eXmp"
              (length->bytes (bytes-length deflated-bstr))
              deflated-bstr
              after))))

(define (set-embed-flif! flif taglist)
  (define old-xmp (get-embed-flif flif))
  (define xexpr (if (empty? old-xmp)
                    ; if the image has no xmp data, generate some
                    (make-xmp-xexpr taglist)
                    (set-dc:subject
                     (string->xexpr (first old-xmp))
                     taglist)))
  (define xmp-str (xexpr->xmp xexpr))
  (set-xmp-flif! flif xmp-str))

; set the XMP data inside the image's iTXt chunk
(define (set-xmp-png! png xmp-str)
  (define png-hash (png->hash png))
  (define itxt-bstr (make-itxt-chunk "XML:com.adobe.xmp" xmp-str))
  (define itxt-hash (make-itxt-hash itxt-bstr))
  (define new-hash (itxt-set png-hash itxt-hash "XML:com.adobe.xmp"))
  (define new-png (hash->png new-hash))
  (call-with-atomic-output-file png (λ (out tmp-png) (void (write-bytes new-png out)))))

; takes a list of strings and embeds them into a valid PNG
(define (set-embed-png! png taglist)
  (define png-hash (png->hash png))
  ; grab the old XMP data as an XEXPR
  (define old-xmp (get-embed-png png-hash))
  (define xexpr (if (empty? old-xmp)
                    ; if the image has no XMP data, generate some
                    (make-xmp-xexpr taglist)
                    ; change the old dc:subject xexpr
                    (set-dc:subject (string->xexpr (first old-xmp)) taglist)))
  (define xmp-str (xexpr->xmp xexpr))
  (set-xmp-png! png xmp-str))

; mess upon mess!
(define (set-xmp-jpeg! jpeg xmp-str)
  (define jpeg-bytes (file->bytes jpeg))
  (define positions
    (call-with-input-bytes
     jpeg-bytes
     (λ (in) (jpeg-goto-marker in APP1))))
  (define app1-lst (jpeg-get-app1 jpeg-bytes))
  (define filtered
    (filter pair?
            (for/list ([app1 (in-list app1-lst)]
                       [i (in-range (length app1-lst))])
              (if (jpeg-xmp? app1)
                  (list-ref positions i)
                  #f))))
  (define pos (if (empty? filtered)
                  empty
                  (car filtered)))
  (define len-bstr (if (empty? filtered)
                       (bytes 0 0)
                       (subbytes jpeg-bytes (cdr pos) (+ (cdr pos) 2))))
  (define len (integer-bytes->integer len-bstr #f #t))
  (define bstr-before (if (empty? filtered)
                          (bytes #xff SOI)
                          (subbytes jpeg-bytes 0 (car pos))))
  (define bstr-after (if (empty? filtered)
                         (subbytes jpeg-bytes 2)
                         (subbytes jpeg-bytes (+ (car pos) len 2))))
  ; create the APP1 byte string
  (define app1-bstr
    (let ([xmp-bstr (string->bytes/utf-8 xmp-str)])
      (define len (+ 2 (bytes-length xmp-bstr) (bytes-length jpeg-XMP-id)))
      (bytes-append (bytes #xff APP1)
                    (integer->integer-bytes len 2 #f #t)
                    jpeg-XMP-id
                    xmp-bstr)))
  (call-with-atomic-output-file
   jpeg
   (λ (out tmp-jpeg)
     ; sandwich the new XMP APP1 beteen the old data
     (fprintf out
              "~a~a~a"
              bstr-before
              app1-bstr
              bstr-after))))

; what a giant mess this is
(define (set-embed-jpeg! jpeg taglist)
  (define jpeg-bytes (file->bytes jpeg))
  (define positions
    (call-with-input-bytes
     jpeg-bytes
     (λ (in) (jpeg-goto-marker in APP1))))
  (define app1-lst (jpeg-get-app1 jpeg-bytes))
  (define app1-xmp (filter bytes?
                           (map (λ (bstr) (if (jpeg-xmp? bstr) bstr empty)) app1-lst)))
  (define filtered
    (filter pair?
            (for/list ([app1 (in-list app1-lst)]
                       [i (in-range (length app1-lst))])
              (if (jpeg-xmp? app1)
                  (list-ref positions i)
                  #f))))
  (define pos (if (empty? filtered)
                  empty
                  (car filtered)))
  (define xmp-str
    (cond [(empty? filtered) (xexpr->xmp (make-xmp-xexpr taglist))]
          [else
           (define bstr-before (subbytes jpeg-bytes 0 (- (car pos) 1)))
           (define xmp-str
             (bytes->string/utf-8 (subbytes (car app1-xmp) (+ 4 (bytes-length jpeg-XMP-id)))))
           (define xexpr (set-dc:subject (string->xexpr xmp-str) taglist))
           (xexpr->xmp xexpr)]))
  (set-xmp-jpeg! jpeg xmp-str))

; embed the XMP string into the gif
(define (set-xmp-gif! gif xmp-str)
  (define bstr (read-gif gif))
  (define new-appn-xmp (make-xmp-appn (string->bytes/utf-8 xmp-str)))
  (define appn-pos (get-appn-pos bstr))
  ; find out which one is the xmp position
  (define pos-pair
    (filter pair?
            (for/list ([pos (in-list appn-pos)])
              (if (gif-appn-xmp? (subbytes bstr (first pos) (+ (first pos) (second pos))))
                  pos
                  #f))))
  ; bytes before the XMP appn chunk
  ; make sure the format is GIF89a, not GIF87a
  (define before-bstr (if (empty? pos-pair)
                          (bytes-append #"GIF89a"
                                        (subbytes bstr 6 (- (bytes-length bstr) 1)))
                          (subbytes bstr 0 (first (first pos-pair)))))
  (define after-bstr (if (empty? pos-pair)
                         (bytes #x3b)
                         (subbytes bstr (+ (first (first pos-pair)) (second (first pos-pair))))))
  (call-with-atomic-output-file
   gif
   (λ (out tmp-gif)
     (fprintf out
              "~a~a~a"
              before-bstr
              new-appn-xmp
              after-bstr))))

; embed the taglist into the gif
; application extension only available for GIF89a!
(define (set-embed-gif! gif taglist)
  (define bstr (read-gif gif))
  ; grab the old XMP data (if available)
  (define old-xmp (get-embed-gif bstr))
  (define xexpr (if (empty? old-xmp)
                    (make-xmp-xexpr taglist)
                    (string->xexpr (first old-xmp))))
  ; xmp string
  (define xmp-str (if (empty? old-xmp)
                      (xexpr->xmp xexpr)
                      (xexpr->xmp (set-dc:subject xexpr taglist))))
  (set-xmp-gif! gif xmp-str))

(define (set-xmp-svg! svg xmp-str)
  (define bstr (file->bytes svg))
  (define start (regexp-match-positions (byte-regexp #"<metadata?") bstr))
  (define end (regexp-match-positions (byte-regexp #"</metadata>") bstr))
  (define before
    (cond [start
           ; find the closing > for the <metadata
           (define close-pos
             (if start
                 (let loop ([end (cdr (car start))])
                   (if (bytes=? (subbytes bstr end (+ end 1)) #">")
                       end
                       (loop (+ end 1))))
                 #f))
           (subbytes bstr 0 (if close-pos
                                (+ close-pos 1)
                                (car (car start))))]
          [else
           (define close-tag (regexp-match-positions (byte-regexp #"</svg>") bstr))
           (subbytes bstr 0 (car (car close-tag)))]))
  (define after (if end
                    (subbytes bstr (cdr (car end)))
                    #"</svg>"))
  (define xmp-bstr
    (bytes-append before
                  (if start #"" #"<metadata>")
                  (string->bytes/utf-8 xmp-str)
                  #"</metadata>"
                  after))
  (call-with-atomic-output-file svg (λ (out tmp-svg) (void (write-bytes xmp-bstr out)))))

(define/contract (set-embed-svg! img taglist)
  ((and/c path-string? embed-support?) (listof string?) . -> . void?)
  (define bstr (file->bytes img))
  (define old-xmp (get-embed-svg bstr))
  (define xexpr (if (empty? old-xmp)
                    (make-xmp-xexpr taglist)
                    (string->xexpr (first old-xmp))))
  (define xmp-str (if (empty? old-xmp)
                      (xexpr->xmp xexpr)
                      (xexpr->xmp (set-dc:subject xexpr taglist))))
  (set-xmp-svg! img xmp-str))

; retrieve the taglist from the XMP data
(define/contract (get-embed-tags img)
  (embed-support? . -> . list?)
  (define embed-xmp (get-embed-xmp img))
  (cond [(empty? embed-xmp) empty]
        [else
         ; turn the XMP string into an XEXPR
         (define xexpr (string->xexpr (first embed-xmp)))
         ; find the dc:subject info
         (define dc:sub-lst (findf*-txexpr xexpr is-dc:subject?))
         (if dc:sub-lst
             ; grab the embedded tags
             (flatten (map dc:subject->list dc:sub-lst))
             empty)]))

(define/contract (get-embed-xmp img)
  (embed-support? . -> . list?)
  (cond [(flif? img) (get-embed-flif img)]
        [(gif? img) (get-embed-gif img)]
        [(jpeg? img) (get-embed-jpeg img)]
        [(png? img) (get-embed-png img)]
        [(svg? img) (get-embed-svg img)]))

; scan the FLIF and grab the metadata without using the
; library at all - no need to decode the image
(define (get-embed-flif flif)
  (define flif-in (if (bytes? flif)
                      (open-input-bytes flif)
                      (open-input-file flif)))
  (define marker-lst (flif-goto-marker flif-in #"eXmp"))
  (cond
    [marker-lst
     (define marker (first marker-lst))
     (define len-bstr
       (let loop ([bstr #""]
                  [pos (cdr marker)])
         (define byte (peek-bytes 1 pos flif-in))
         (if (< (bytes-ref byte 0) flif-separator)
             (bytes-append bstr byte)
             (loop (bytes-append bstr byte) (+ pos 1)))))
     (define len (bytes->length len-bstr))
     (define xmp-deflated (peek-bytes len (+ (cdr marker) 2) flif-in))
     (close-input-port flif-in)
     ; inflate the data
     (define inflate-in (open-input-bytes xmp-deflated))
     (define inflate-out (open-output-bytes))
     ; catch possible malformed compressed data
     (with-handlers ([exn:fail? (λ (e)
                                  (eprintf "~a\n" (exn-message e))
                                  (close-input-port inflate-in)
                                  (close-output-port inflate-out)
                                  empty)])
       (inflate inflate-in inflate-out))
     (define inflated (get-output-bytes inflate-out))
     (close-input-port inflate-in)
     (close-output-port inflate-out)
     (list (bytes->string/utf-8 inflated))]
    [else empty]))

; retrieve the XMP data located inside the iTXt block(s)
(define (get-embed-png png)
  (define png-hash (if (hash? png) png (png->hash png)))
  (define itxt-lst
    (filter string?
            (if (hash-has-key? png-hash 'iTXt)
                (map (λ (hsh)
                       (define inner (hash-ref hsh 'data))
                       (if (bytes=? #"XML:com.adobe.xmp" (hash-ref inner 'keyword))
                           ; the XMP string
                           (bytes->string/utf-8 (hash-ref inner 'text))
                           inner))
                     (hash-ref png-hash 'iTXt))
                empty)))
  (if (empty? itxt-lst)
      empty
      itxt-lst))

(define/contract (get-embed-jpeg jpeg)
  (jpeg? . -> . (listof string?))
  (define jpeg-bytes (if (bytes? jpeg)
                         jpeg
                         (file->bytes jpeg)))
  ; only one XMP block allowed in a jpeg file
  (define xmp-lst (filter jpeg-xmp? (jpeg-get-app1 jpeg-bytes)))
  (if (empty? xmp-lst)
      empty
      (list
       (bytes->string/utf-8
        (subbytes (car xmp-lst) (+ 4 (bytes-length jpeg-XMP-id)))))))

; grab the taglist from the embedded XMP data
(define/contract (get-embed-gif img)
  (gif? . -> . (listof string?))
  (define bstr (read-gif img))
  (define appn-lst (gif-get-appn bstr))
  (define filtered (filter gif-appn-xmp? appn-lst))
  (if (empty? filtered)
      empty
      (list
       (bytes->string/utf-8
        (subbytes (first filtered)
                  (+ (bytes-length gif-XMP-header) 3)
                  ; due to "magic trailer", the last 258 bytes are garbage
                  (- (bytes-length (first filtered)) 258))))))

(define/contract (get-embed-svg svg)
  (svg? . -> . (listof string?))
  (define bstr (if (bytes? svg)
                   svg
                   (file->bytes svg)))
  (define in (open-input-bytes bstr))
  (cond [(svg-has-tag? in #"<metadata?")
         ; obtain the metadata text (sans tags)
         (define start (regexp-match-positions (byte-regexp #"<metadata?") bstr))
         ; find the closing > for the <metadata
         (define close-pos
           (cond [start
                  (let loop ([end (cdr (car start))])
                    (if (bytes=? (subbytes bstr end (+ end 1)) #">")
                        end
                        (loop (+ end 1))))]
                 [else #f]))
         (define end (regexp-match-positions (byte-regexp #"</metadata>") bstr))
         (close-input-port in)
         (list
          (bytes->string/utf-8
           (subbytes bstr (if close-pos
                              (+ close-pos 1)
                              (cdr (car start)))
                     (car (car end)))))]
        [else (close-input-port in) empty]))

; remove the tags in taglist from the image
(define/contract (del-embed-tags! img taglist)
  (embed-support? (or/c list? string?) . -> . void?)
  ; get the tags from the image (if any)
  (define embed-lst (get-embed-tags img))
  (define resolved-tag-lst
    (if (list? taglist)
        taglist
        (list taglist)))
  (unless (empty? embed-lst)
    ; remove taglist items from embed-list
    (define new-taglist (remove* resolved-tag-lst embed-lst))
    (set-embed-tags! img new-taglist)))

(define ((is-tag? sym) xexpr) (and (txexpr? xexpr) (eq? sym (get-tag xexpr))))
(define is-dc:subject? (is-tag? 'dc:subject))
(define is-rdf:li? (is-tag? 'rdf:li))
(define is-rdf:Description? (is-tag? 'rdf:Description))
(define is-rdf:RDF? (is-tag? 'rdf:RDF))
(define is-xmp:MetaDate? (is-tag? 'xmp:MetadataDate))

; take a list of tags and return a dc:subject entry
(define/contract (list->dc:subject lst)
  (list? . -> . is-dc:subject?)
  (txexpr 'dc:subject '()
          (list
           (for/fold ([bag '(rdf:Bag ())])
                     ([tag (in-list lst)])
             (append bag `((rdf:li () ,tag)))))))

; fixes issues when we have multiple elements inside a single rdf:li
; enter a single rdf:li, return a single string
(define/contract (rdf:li-fixer rdf:li)
  (is-rdf:li? . -> . string?)
  (define elem (get-elements rdf:li))
  (if (> (length elem) 1)
      (apply string-append elem)
      (first elem)))

; take a dc:subject entry and return a list of tags
(define/contract (dc:subject->list dc:sub)
  (is-dc:subject? . -> . list?)
  (define found (findf*-txexpr dc:sub is-rdf:li?))
  (if found
      (map rdf:li-fixer found)
      empty))

; set the tag inside xexpr with the contents of tx.
; if xexpr doesn't have tag, generate the missing
; parts so it has a coherent structure.
(define/contract ((set-xmp-tag tag) xexpr tx)
  (symbol? . -> . (txexpr? txexpr? . -> . txexpr?))
  (define-values (replaced-tx old-tx)
    ; if tag is found, replace it with tx
    (splitf-txexpr xexpr (is-tag? tag) (λ (x) tx)))
  (cond
    ; empty old-tx means it has no existing tx
    [(empty? old-tx)
     (define rdf:desc (findf-txexpr replaced-tx is-rdf:Description?))
     (cond
       ; xexpr has existing rdf:Description
       [rdf:desc
        (define-values (without-rdf:desc old-desc)
          (splitf-txexpr xexpr is-rdf:Description?))
        ; if there's more than one rdf:Description, merge them
        (define new-desc
          (for/fold ([accum (first old-desc)])
                    ([r:d (in-list (rest old-desc))]
                     [i (in-naturals)])
            (define attrs (get-attrs r:d))
            (define elems (get-elements r:d))
            (for/fold ([xpr (append accum elems)])
                      ([attr-pair (in-list attrs)])
              (attr-set xpr (first attr-pair) (second attr-pair)))))
        ; build the xexpr with the new tx
        (define-values (without-rdf:rdf old-rdf:rdf) (splitf-txexpr without-rdf:desc is-rdf:RDF?))
        (append
         without-rdf:rdf
         (list
          (append (first old-rdf:rdf)
                  (list
                   (append (attr-set new-desc 'xmp:MetadataDate (get-time)) (list tx))))))]
       ; xexpr has no existing rdf:Description
       [else
        (define-values (without-rdf:rdf old-rdf:rdf) (splitf-txexpr xexpr is-rdf:RDF?))
        (append
         without-rdf:rdf
         (list
          (append (first old-rdf:rdf)
                  `((rdf:Description
                     ((rdf:about "")
                      (xmlns:Iptc4xmpCore "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/")
                      (xmlns:dc "http://purl.org/dc/elements/1.1/")
                      (xmlns:xmp "http://ns.adobe.com/xap/1.0/")
                      (xmlns:xmpRights "http://ns.adobe.com/xap/1.0/rights/")
                      (xmp:MetadataDate ,(get-time))
                      (xmp:Rating "0"))
                     ,tx)))))])]
    ; xexpr had an old tx (which got replaced)
    [else
     ; set the xmp:MetadataDate
     (define rdf:desc (findf-txexpr replaced-tx is-rdf:Description?))
     (define-values (replaced-desc old-desc)
       (splitf-txexpr replaced-tx is-rdf:Description?
                      (λ (x) (attr-set x 'xmp:MetadataDate (get-time)))))
     replaced-desc]))

(define/contract (set-dc:subject xexpr lst)
  (txexpr? (listof string?) . -> . txexpr?)
  (define dc:sub (list->dc:subject lst))
  ((set-xmp-tag 'dc:subject) xexpr dc:sub))

; take a taglist and return a complete xexpr (sans header and footer)
(define/contract (make-xmp-xexpr taglist)
  (list? . -> . txexpr?)
  (define dc:sub (list->dc:subject taglist))
  (txexpr 'x:xmpmeta
          `((x:xmptk ,(format "Ivy Image Viewer ~a" ivy-version)) (xmlns:x "adobe:ns:meta/"))
          `((rdf:RDF
             ((xmlns:rdf "http://www.w3.org/1999/02/22-rdf-syntax-ns#"))
             (rdf:Description
              ((rdf:about "")
               (xmlns:dc "http://purl.org/dc/elements/1.1/")
               (xmlns:xmp "http://ns.adobe.com/xap/1.0/")
               (xmlns:xmpRights "http://ns.adobe.com/xap/1.0/rights/")
               (xmp:MetadataDate ,(get-time))
               (xmp:Rating "0"))
              ,dc:sub)))))

; take the complete xexpr (possibly from make-xmp-xexpr) and
; return a complete xmp string with header and footer
(define/contract (xexpr->xmp xexpr)
  (txexpr? . -> . string?)
  (string-append
   ; xmp packet header
   "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
   ; xmp packet content
   (xexpr->string xexpr)
   ; xmp packet footer
   "<?xpacket end=\"w\"?>"))

(define (get-time)
  (define cd (current-date))
  (define tz (date-time-zone-offset cd))
  (string-append
   (number->string (date-year cd))
   "-"
   (~r (date-month cd) #:min-width 2 #:pad-string "0")
   "-"
   (~r (date-day cd) #:min-width 2 #:pad-string "0")
   "T"
   (~r (date-hour cd) #:min-width 2 #:pad-string "0")
   ":"
   (~r (date-minute cd) #:min-width 2 #:pad-string "0")
   ":"
   (~r (date-second cd) #:min-width 2 #:pad-string "0")
   ; reports SECONDS, not HOURS adjustment
   (~r (floor (/ tz 3600)) #:min-width 2 #:pad-string "0")
   ; check for weird time zones
   (case (modulo tz 3600)
     [(0) ":00"]
     [(900) ":15"]
     [(1800) ":30"]
     [(2700) ":45"])))

(define (xmp-rating xmp)
  (define xexpr (string->xexpr xmp))
  (define rdf-desc (findf-txexpr xexpr (is-tag? 'rdf:Description)))
  (cond [rdf-desc
         ; attr may be a number via xmp:Rating
         (define found (findf-txexpr xexpr (is-tag? 'xmp:Rating)))
         (define attr (attr-ref rdf-desc 'xmp:Rating (λ _ "")))
         (define attr-str
           (if (number? attr)
               (number->string attr)
               attr))
         ; if it doesn't exist as an attr, check if it's an element
         (cond [(and found (string=? attr-str ""))
                (car (get-elements found))]
               ; does not have xmp:Rating (yet)
               [(and (not found) (string=? attr-str "")) "0"]
               [else attr-str])]
        [else "0"]))
