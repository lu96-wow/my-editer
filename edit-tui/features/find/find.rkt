#lang racket

;;; edit-tui/features/find/find.rkt —— 当前 buffer 查找 / 前后移动
;;;
;;; C-x f 打开输入栏；提交后在当前 view 内找 query，选中第一个匹配。
;;; C-left / C-right 在 matches 中前后移动；越界循环。
;;;
;;; 查找状态放在 session 的 find slot；不写 plugin-state。

(require racket/string
         "../../editor/api.rkt"
         "../input/api.rkt"
         "model.rkt")

(provide find-open-prompt!
         find-submit!
         find-next!
         find-prev!)

;;; ════════════════ 文本 / point ════════════════

(define (offset->point text offset)
  (define n (min (max 0 offset) (string-length text)))
  (let loop ([i 0] [line 0] [col 0])
    (cond
      [(>= i n) (point line col)]
      [(char=? (string-ref text i) #\newline)
       (loop (add1 i) (add1 line) 0)]
      [else (loop (add1 i) line (add1 col))])))

(define (string-find text query start)
  (define n (string-length text))
  (define m (string-length query))
  (let loop ([i start])
    (cond
      [(> (+ i m) n) #f]
      [(string=? (substring text i (+ i m)) query) i]
      [else (loop (add1 i))])))

(define (text->matches text query)
  (define qlen (string-length query))
  (cond
    [(zero? qlen) '()]
    [else
     (let loop ([start 0] [acc '()])
       (define pos (string-find text query start))
       (cond
         [(not pos) (reverse acc)]
         [else
          (loop (+ pos qlen)
                (cons (range (offset->point text pos)
                             (offset->point text (+ pos qlen)))
                      acc))]))]))

(define (point< a b)
  (or (< (point-line a) (point-line b))
      (and (= (point-line a) (point-line b))
           (< (point-column a) (point-column b)))))

(define (index-nearest matches line col)
  (define current (point line col))
  (or (for/first ([m (in-list matches)]
                  [i (in-naturals)]
                  #:when (not (point< (range-start m) current)))
        i)
      0))

(define (find-at-index ed state st index)
  (define vid (find-state-target-vid st))
  (define r (list-ref (find-state-matches st) index))
  (define-values (s1 a1)
    (editor-select! ed state vid
                    (selections-one
                     (selection (range-start r) (range-end r)))))
  (define-values (s2 a2) (editor-ensure! ed s1 vid))
  (define n (length (find-state-matches st)))
  (values (state-with-find
           (state-with-flash s2 (format "find ~a/~a" (add1 index) n))
           (struct-copy find-state st [index index]))
          (append a1 a2)))

;;; ════════════════ prompt ════════════════

(define (find-open-prompt! state)
  (define vid (editor-focus-view-id state))
  (cond
    [(not vid) (values (state-with-flash state "find: no focused view") '())]
    [else
     (define st (state-find state))
     (define prev (and (find-state? st) (find-state-query st)))
     (values (editor-input-open state
                                'find
                                "Find: "
                                (list 'find vid)
                                #:text (or prev ""))
             '())]))

;;; ════════════════ submit ════════════════

(define (find-submit! ed state context text)
  (match-define (list 'find vid) context)
  (define query text)
  (define text* (editor-view-text ed vid))
  (define did (editor-view-doc-id ed vid))
  (define version (and did (editor-doc-version ed did)))
  (cond
    [(or (not text*) (string=? query ""))
     (values (state-with-find
              (editor-input-close (state-with-flash state "find: empty query"))
              (find-state "" vid version '() 0))
             '())]
    [else
     (define matches (text->matches text* query))
     (define state1 (editor-input-close state))
     (cond
       [(null? matches)
        (values (state-with-find
                 (state-with-flash state1 (format "find: no match: ~a" query))
                 (find-state query vid version '() 0))
                '())]
       [else
        (define line (or (editor-view-point-line ed vid) 0))
        (define col (or (editor-view-point-column ed vid) 0))
        (define idx (index-nearest matches line col))
        (find-at-index ed state1
                       (find-state query vid version matches 0)
                       idx)])]))

;;; ════════════════ next / prev ════════════════

(define (find-current ed state)
  (define st (state-find state))
  (cond
    [(not (find-state? st)) #f]
    [(string=? (find-state-query st) "") #f]
    [else
     ;; 查找跟随当前 focus view；切换 buffer 后 C-left / C-right 在新 buffer 里找。
     (define vid (or (editor-focus-view-id state) (find-state-target-vid st)))
     (define text (and vid (editor-view-text ed vid)))
     (define did (and vid (editor-view-doc-id ed vid)))
     (define version (and did (editor-doc-version ed did)))
     (cond
       [(or (not vid) (not text) (not version)) #f]
       [else
        (define matches (text->matches text (find-state-query st)))
        (define same? (and (equal? vid (find-state-target-vid st))
                           (equal? version (find-state-target-version st))
                           (equal? matches (find-state-matches st))))
        (define idx
          (if same?
              (find-state-index st)
              (index-nearest matches
                             (or (editor-view-point-line ed vid) 0)
                             (or (editor-view-point-column ed vid) 0))))
        (find-state (find-state-query st) vid version matches idx)])]))

(define (find-move! ed state step)
  (define st (find-current ed state))
  (cond
    [(not st) (values (state-with-flash state "find: no active query") '())]
    [(null? (find-state-matches st))
     (values (state-with-flash state "find: no match") '())]
    [else
     (define n (length (find-state-matches st)))
     (define idx (modulo (+ (find-state-index st) step) n))
     (find-at-index ed state st idx)]))

(define (find-next! ed state)
  (find-move! ed state 1))

(define (find-prev! ed state)
  (find-move! ed state -1))
