#lang racket

;;; ============================================================================
;;; tree-prompt.rkt —— 文件树提示行：状态机
;;; ============================================================================
;;;
;;; 建 / 删文件的输入行逻辑都在这儿，和投影、按键分发、树结构解耦：
;;;   prompt-begin      开一个提示
;;;   prompt-type       追加用户输入（普通字符 / 粘贴）
;;;   prompt-backspace  退格
;;;   prompt-cancel     取消
;;;   prompt-key        按键 → 状态机
;;;   prompt-confirm    回车：执行文件动作 → 刷新目录 → 落点 + effects
;;;
;;; 只依赖：tree-model（状态）+ tree-files（磁盘）+ input（键值词汇）。

(require "tree-model.rkt"
         "tree-files.rkt"
         "input.rkt")

(provide prompt-active?
         prompt-begin
         prompt-type
         prompt-backspace
         prompt-cancel
         prompt-key
         prompt-confirm)

(define (prompt-active? st) (tree-prompt-active? st))

(define (prompt-begin st kind label data) (tree-set-prompt st kind label data))

(define (prompt-type st s)
  (tree-set-prompt-value st (string-append (prompt-value (tree-prompt st)) s)))

(define (prompt-backspace st)
  (define v (prompt-value (tree-prompt st)))
  (tree-set-prompt-value st (if (string=? v "") "" (substring v 0 (sub1 (string-length v))))))

(define (prompt-cancel st) (tree-clear-prompt st))

(define (plain? k) (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

;; 提示行里只认：普通字符（追加）、退格、回车、Esc；其余忽略。
(define (prompt-key st opened k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (char? n)) (values (prompt-type st (string n)) '())]
    [(and (plain? k) (eq? n 'escape)) (values (prompt-cancel st) '())]
    [(and (plain? k) (eq? n 'enter)) (prompt-confirm st opened)]
    [(and (plain? k) (eq? n 'backspace)) (values (prompt-backspace st) '())]
    [else (values st '())]))

;; 回车：按 kind 执行 → 刷新被改动的目录 → （新建时）落点到新项 → 返回 effects。
(define (prompt-confirm st opened)
  (define p (tree-prompt st))
  (define val (prompt-value p))
  (define result-path
    (case (prompt-kind p)
      [(file) (and (not (string=? val "")) (create-file! (prompt-data p) val))]
      [(dir) (and (not (string=? val "")) (create-dir! (prompt-data p) val))]
      [(delete) (and (string-ci=? val "y") (remove! (prompt-data p)))]
      [else #f]))
  ;; **刷新被改动的目录**：新建刷目标目录；删除刷它**父目录**（而不是被删的路径）。
  (define refresh-dir
    (case (prompt-kind p)
      [(file dir) (prompt-data p)]
      [(delete) (and result-path (parent-path result-path))]
      [else #f]))
  (define st1 (tree-clear-prompt st))
  (define st2 (if refresh-dir (tree-refresh-dir st1 refresh-dir) st1))
  (define st3 (if (and result-path (memq (prompt-kind p) '(file dir)))
                  (tree-set-goto st2 result-path)
                  st2))
  ;; 删除的若正被打开 → 让 state 关掉那个文档。
  (define effs
    (if (and (eq? (prompt-kind p) 'delete) result-path)
        (let ([did (for/first ([(path d) (in-hash opened)] #:when (equal? path result-path)) d)])
          (if did (list (list 'close-document did)) '()))
        '()))
  (values st3 effs))
