#lang racket

;;; lab-rebuild/smoke-plugin.rkt —— 属性插件（高亮）+ 输入插件（自动配对）冒烟
;;;
;;; 验证：括号纯扫描；app 里 before-render 把高亮写回 document；
;;; 打字触发 auto-pair（插成对 / 跳过闭括号）。

(require rackunit
         racket/file
         racket/path
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "app/app.rkt"
         "builtin/edit.rkt"
         "builtin/highlight/bracket-pair.rkt"
         "builtin/highlight/lex.rkt"
         "builtin/highlight/api.rkt"
         "builtin/highlight/words.rkt"
         "builtin/indent.rkt"
         "platform/face.rkt"
         "platform/state.rkt"
         "platform/panes.rkt"
         "platform/input.rkt"
         "config/theme/main.rkt")

;;; ---------- 纯括号扫描 ----------

(define (covers? f line col)
  (match-define (list l0 c0 l1 c1 _) f)
  (cond [(= l0 l1) (and (= line l0) (<= c0 col) (< col c1))]
        [(= line l0) (>= col c0)]
        [(= line l1) (< col c1)]
        [else (and (> line l0) (< line l1))]))
(define (face-at fills line col)
  (for/fold ([acc #f]) ([f (in-list fills)] #:when (covers? f line col))
    (list-ref f 4)))

(define bf (bracket-fills "(a[b]c)"))
(check-equal? (palette-color-index (face-at bf 0 0)) 0)
(check-equal? (palette-color-index (face-at bf 0 2)) 1)
(check-equal? (palette-color-index (face-at bf 0 4)) 1)   ; ] 在内层
(check-equal? (palette-color-index (face-at bf 0 5)) 0)   ; c 在外层
(check-false (face-at (bracket-fills "(]") 0 0))

;;; ---------- 词法：Unicode 字母（中文等 CJK）也能成词 ----------

(check-equal? (map (lambda (t) (list-ref t 3)) (scan-words "你好 世界 abc 变量2"))
              '("你好" "世界" "abc" "变量2"))
(let-values ([(_ fl) ((plugin-open word-plugin) "你好 世界 你好" "/w.txt")])
  (check-equal? (length fl) 3)
  (check-equal? (list-ref (car fl) 4) (palette-color 'word 0))       ; 你好
  (check-equal? (list-ref (cadr fl) 4) (palette-color 'word 1))      ; 世界
  (check-equal? (list-ref (caddr fl) 4) (palette-color 'word 0)))    ; 你好（同词同色）

;;; ---------- app：属性插件写回高亮 ----------

(define root (simplify-path (path->complete-path (make-temporary-file "pl~a" 'directory))))
(define f (build-path root "code.rkt"))
(with-output-to-file f #:exists 'replace
  (lambda () (display "#lang racket\n(define (a b) a)\n")))

(define a (app-init root 100 30))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))
(app-open-path! a f)
(define vid (app-focus a))
(define did (editor-view-document-id (ed) vid))

;; app-render 内部走 before-render → 插件同步 + 写回
(void (app-render a))

(define (palette-of v kind)
  ;; 括号区间会叠层（外层 + 内层），取最内层（last），与 core 写回一致。
  (for/last ([l (in-list (face-layers v))]
             #:when (and (palette-color? l) (eq? (palette-color-kind l) kind))) l))

;; define 的 d 上：既有括号背景，也有关键字前景（叠层）
(define hl (editor-document-highlight-at (ed) did 1 1))
(check-not-false (palette-of hl 'keyword))
(check-equal? (palette-color-index (palette-of hl 'bracket)) 0)
;; 内层 ( 起始：括号深度 1
(check-equal? (palette-color-index
               (palette-of (editor-document-highlight-at (ed) did 1 8) 'bracket))
              1)

;;; ---------- 输入插件：自动配对 ----------

(define f2 (build-path root "pair.txt"))
(with-output-to-file f2 #:exists 'replace (lambda () (void)))
(app-open-path! a f2)
(define vid2 (app-focus a))

(send (key-event #\( no-mods))
(check-equal? (editor-view-string (ed) vid2) "()")
(check-equal? (editor-view-point-column (ed) vid2) 1)      ; 光标在中间
(send (key-event #\) no-mods))                              ; 右边已是 ) → 跳过
(check-equal? (editor-view-string (ed) vid2) "()")
(check-equal? (editor-view-point-column (ed) vid2) 2)
(send (key-event #\[ no-mods))
(check-equal? (editor-view-string (ed) vid2) "()[]")

;; 渲染不崩
(check-not-false (screen? (app-render a)))

;;; ---------- 后台 place runner（#:background? #t） ----------

(define a2 (app-init root 100 30 #:background? #t))
(app-open-path! a2 f)
(define vid3 (app-focus a2))
(define did3 (editor-view-document-id (app-ed a2) vid3))

(define (wait-hl! n)
  (cond
    [(zero? n) #f]
    [else
     (app-prepare! a2)                                  ; before-render → sync + poll
     (define v (editor-document-highlight-at (app-ed a2) did3 1 1))
     (if (and v (palette-of v 'keyword))
         #t
         (begin (sleep 0.05) (wait-hl! (sub1 n))))]))

(check-true (wait-hl! 200))                             ; ≤10s 内高亮写回
(check-equal? (palette-color-index
               (palette-of (editor-document-highlight-at (app-ed a2) did3 1 8) 'bracket))
              1)

;;; ---------- 换行语法缩进 ----------

(check-equal? (indent-for "(define (f x)" 0 13) 2)
(check-equal? (indent-for "(define x 1)" 0 12) 0)
(check-equal? (indent-for "(let ([x 1])" 0 12) 2)
(check-equal? (indent-for "\"(\" x" 0 5) 0)           ; 字符串里的 ( 不算

(define f3 (build-path root "indent.rkt"))
(with-output-to-file f3 #:exists 'replace (lambda () (display "(define (f x)")))
(app-open-path! a f3)
(define vid4 (app-focus a))
(editor-view-set-point! (ed) vid4 (point 0 13))
(send (key-event 'enter no-mods))
(check-equal? (editor-view-string (ed) vid4) "(define (f x)\n  ")

(displayln "plugin smoke: ok")
