#lang racket

;;; edit-tui/features/replace/replace.rkt —— 选中文本驱动的全局替换
;;;
;;; C-x c：
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

(define (string-find text query start)
  (define n (string-length text))
  (define m (string-length query))
  (let loop ([i start])
    (cond
      [(> (+ i m) n) #f]
      [(string=? (substring text i (+ i m)) query) i]
      [else (loop (add1 i))])))

;; 在原始文本上扫描；target 里再次出现 source 不会被继续替换。
(define (string-replace-all text source target)
  (define m (string-length source))
  (cond
    [(zero? m) (values text 0)]
    [else
     (define out (open-output-string))
     (let loop ([start 0] [count 0])
       (define pos (string-find text source start))
       (cond
         [(not pos)
          (write-string (substring text start) out)
          (values (get-output-string out) count)]
         [else
          (write-string (substring text start pos) out)
          (write-string target out)
          (loop (+ pos m) (add1 count))]))]))

(define (prompt-label s)
  (define one-line (string-replace s "\n" "\\n"))
  (define max-len 24)
  (if (> (string-length one-line) max-len)
      (string-append (substring one-line 0 max-len) "...")
      one-line))

(define (replace-open-prompt! ed state)
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
          (format "Replace ~s with: " (prompt-label source))
          (list 'replace-global vid source))
         '())])]))

(define (replace-submit! ed state context text)
  (match-define (list 'replace-global vid source) context)
  (define old-text (editor-view-text ed vid))
  (define state* (editor-input-close state))
  (cond
    [(or (not old-text) (string=? source ""))
     (values (state-with-flash state* "replace: invalid selection") '())]
    [(string=? source text)
     (values (state-with-flash state* "replace: source and target are the same")
             '())]
    [else
     (define-values (new-text count) (string-replace-all old-text source text))
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
