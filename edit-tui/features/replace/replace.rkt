#lang racket

;;; edit-tui/features/replace/replace.rkt —— 选中文本驱动的全局替换
;;;
;;; C-x c f：完整匹配（选中文本必须是独立标识符 / token）
;;; C-x c s：子字符串匹配
;;;
;;; 流程：
;;;   1. 取当前 view 的主选区文本作为源字符串；
;;;   2. 打开输入栏输入目标字符串；
;;;   3. 提交后替换当前 buffer 内所有非重叠出现。
;;;
;;; 替换走 editor-replace-text!：程序化文本写、一个 undo step、进入 changes 流。

(require racket/string
         "../../editor/api.rkt"
         "../input/api.rkt")

(provide replace-open-prompt!
         replace-submit!)

;; 完整匹配的边界字符：标识符字符。
;; define 不会命中 define-value / define? / define/contract。
(define (identifier-char? c)
  (or (char-alphabetic? c)
      (char-numeric? c)
      (memv c '(#\_ #\- #\? #\! #\* #\+ #\/ #\< #\> #\= #\% #\&))))

(define (full-match-at? text source pos)
  (define end (+ pos (string-length source)))
  (and (or (zero? pos)
           (not (identifier-char? (string-ref text (sub1 pos)))))
       (or (= end (string-length text))
           (not (identifier-char? (string-ref text end))))))

;; 在原始文本上扫描；target 里再次出现 source 不会被继续替换。
;; mode : 'full | 'substring
(define (string-replace-all text source target mode)
  (define m (string-length source))
  (cond
    [(zero? m) (values text 0)]
    [else
     (define out (open-output-string))
     (define rx (regexp (regexp-quote source)))
     (let loop ([search-start 0] [copy-start 0] [count 0])
       (define mr (regexp-match-positions rx text search-start))
       (define pos (and mr (caar mr)))
       (cond
         [(not pos)
          (write-string (substring text copy-start) out)
          (values (get-output-string out) count)]
         [(or (eq? mode 'substring)
              (full-match-at? text source pos))
          (write-string (substring text copy-start pos) out)
          (write-string target out)
          (loop (+ pos m) (+ pos m) (add1 count))]
         [else
          (loop (add1 pos) copy-start count)]))]))

(define (prompt-label s)
  (define one-line (string-replace s "\n" "\\n"))
  (define max-len 24)
  (if (> (string-length one-line) max-len)
      (string-append (substring one-line 0 max-len) "...")
      one-line))

(define (mode-label mode)
  (case mode
    [(full) "word"]
    [(substring) "substring"]
    [else (error 'replace-open-prompt! "未知 replace mode：~a" mode)]))

(define (replace-open-prompt! ed state mode)
  (define vid (editor-focus-view-id state))
  (cond
    [(not vid)
     (values (state-with-flash state "replace: no focused view") '())]
    [(not (eq? (editor-view-kind ed vid) 'user))
     (values (state-with-flash state "replace: focus is not a user document") '())]
    [else
     (define r (editor-view-primary-range ed vid))
     (define source (and r (editor-view-range-text ed vid r)))
     (cond
       [(or (not r) (range-empty? r) (not source) (string=? source ""))
        (values (state-with-flash state "replace: no selection") '())]
       [else
        (values
         (editor-input-open
          state
          'replace-global
          (format "Replace ~a ~s with: " (mode-label mode) (prompt-label source))
          (list 'replace-global mode vid source))
         '())])]))

(define (replace-submit! ed state context text)
  (match-define (list 'replace-global mode vid source) context)
  (define old-text (editor-view-text ed vid))
  (define state* (editor-input-close state))
  (cond
    [(or (not old-text) (string=? source ""))
     (values (state-with-flash state* "replace: invalid selection") '())]
    [(string=? source text)
     (values (state-with-flash state* "replace: source and target are the same")
             '())]
    [else
     (define-values (new-text count) (string-replace-all old-text source text mode))
     (cond
       [(zero? count)
        (values (state-with-flash state*
                                 (format "replace: no match: ~a" source))
                '())]
       [else
        (define-values (state** actions)
          (editor-replace-text! ed state* vid new-text))
        (values (state-with-flash
                 state**
                 (format "replaced ~a occurrence~a"
                         count (if (= count 1) "" "s")))
                actions)])]))
