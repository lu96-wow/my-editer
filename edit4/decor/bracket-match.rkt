#lang racket

;;; edit4/decor/bracket-match.rkt —— 光标在括号上时高亮**配对**括号（增量，光标驱动）
;;;
;;; 只有两个格：光标处（或紧邻）的括号、它的配对括号。状态 = (光标 . 上次配对位置)；
;;; change 只重拼「旧配对行 ∪ 新配对行」，配对搜索本身仍是全篇一次（与旧实现同阶）。
;;;
;;; 与 decor/bracket-depth.rkt 分开：一个管「深度底色」，一个管「配对高亮」。

(provide bracket-match-decor match-brackets bracket-at)

(require racket/string racket/list
         "../view/face.rkt"
         "protocol.rkt"
         "dirty.rkt"
         (only-in "../../core/text/base/track.rkt" track-length track-ref track-splice))

(define opens '(#\( #\[ #\{))
(define closes '(#\) #\] #\}))

(define (opener? c) (and c (memv c opens) #t))
(define (closer? c) (and c (memv c closes) #t))

(define (line-col->index text line col)
  (let loop ([i 0] [l 0])
    (cond
      [(= l line) (+ i col)]
      [(>= i (string-length text)) (string-length text)]
      [(char=? #\newline (string-ref text i)) (loop (add1 i) (add1 l))]
      [else (loop (add1 i) l)])))

(define (index->line-col text i)
  (let loop ([j 0] [l 0] [c 0])
    (cond
      [(>= j i) (cons l c)]
      [(>= j (string-length text)) (cons l c)]
      [(char=? #\newline (string-ref text j)) (loop (add1 j) (add1 l) 0)]
      [else (loop (add1 j) l (add1 c))])))

(define (bracket-at text line col)
  (define i (line-col->index text line col))
  (define n (string-length text))
  (define (bracket-idx j)
    (and (>= j 0) (< j n)
         (let ([c (string-ref text j)]) (and (or (opener? c) (closer? c)) j))))
  (or (bracket-idx i) (bracket-idx (sub1 i))))

(define (match-forward text i)
  (define n (string-length text))
  (define c (string-ref text i))
  (define close (case c [(#\() #\)] [(#\[) #\]] [(#\{) #\}] [else #f]))
  (let loop ([j (add1 i)] [depth 0])
    (cond
      [(>= j n) #f]
      [(eqv? (string-ref text j) c) (loop (add1 j) (add1 depth))]
      [(eqv? (string-ref text j) close) (if (zero? depth) j (loop (add1 j) (sub1 depth)))]
      [else (loop (add1 j) depth)])))

(define (match-backward text i)
  (define c (string-ref text i))
  (define open (case c [(#\)) #\(] [(#\]) #\[] [(#\}) #\{] [else #f]))
  (let loop ([j (sub1 i)] [depth 0])
    (cond
      [(< j 0) #f]
      [(eqv? (string-ref text j) c) (loop (sub1 j) (add1 depth))]
      [(eqv? (string-ref text j) open) (if (zero? depth) j (loop (sub1 j) (sub1 depth)))]
      [else (loop (sub1 j) depth)])))

;; 光标处（或紧邻）的括号及其配对括号位置 (listof (line . col))。
(define (match-brackets text line col)
  (define i (bracket-at text line col))
  (if (not i)
      '()
      (let* ([c (string-ref text i)]
             [partner (if (opener? c) (match-forward text i) (match-backward text i))])
        (if partner
            (list (index->line-col text i) (index->line-col text partner))
            '()))))

;;; ---------- 装饰 ----------

;; 一行的配对括号标记。
(define (line-marks pos ln line)
  (define vec (make-vector (string-length line) #f))
  (for ([p (in-list pos)] #:when (= ln (car p)))
    (define c (cdr p))
    (when (< c (vector-length vec)) (vector-set! vec c 'bracket-match)))
  vec)

(define bracket-match-decor
  (decor
   (lambda (_path text)
     (values (cons #f '())
             (scan-track text (lambda (ln line) (line-marks '() ln line)))))
   (lambda (state layer ctx)
     (define changes (face-ctx-changes ctx))
     (define cursor (face-ctx-cursor ctx))
     (define last-cursor (car state))
     (define old-pos (cdr state))
     (cond
       ;; 无编辑且光标未动 → 不重扫（帧间空转）
       [(and (null? changes) (equal? last-cursor cursor)) (values state layer (dirty-lines '()))]
       [else
        (define text (face-ctx-new-text ctx))
        (define new-pos (if cursor
                            (match-brackets (track->string text) (car cursor) (cdr cursor))
                            '()))
        (define lines (sort (remove-duplicates
                             (append (map car old-pos) (map car new-pos))) <))
        (define layer*
          (for/fold ([ly layer]) ([ln (in-list lines)])
            (if (< ln (track-length text))
                (track-splice ly ln (add1 ln) (list (line-marks new-pos ln (track-ref text ln))))
                ly)))
        (values (cons cursor new-pos) layer* (dirty-lines lines))]))))
