#lang racket

;;; lab/smoke-plugin.rkt —— 插件层冒烟
;;;
;;; 覆盖：括号纯扫描 / 插件协议 / 版本闸门 / 合并（同步 runner）/ 后台 place runner。

(require rackunit
         "../core/editor.rkt"
         "base/face.rkt"
         "base/brackets.rkt"
         "plugin/api.rkt"
         "plugin/brackets.rkt"
         "plugin/words.rkt"
         "plugin/syntax.rkt"
         "plugin/manager.rkt"
         "plugin/runner.rkt"
         "plugin/runner-place.rkt"
         "plugin/registry.rkt"
         "plugin/shadow.rkt"
         "theme/main.rkt")

;;; ---------- 纯扫描：整对区间上色，内层覆盖外层 ----------

(define (covers? f line col)
  (match-define (list l0 c0 l1 c1 _) f)
  (cond [(= l0 l1) (and (= line l0) (<= c0 col) (< col c1))]
        [(= line l0) (>= col c0)]
        [(= line l1) (< col c1)]
        [else (and (> line l0) (< line l1))]))
(define (face-at fills line col)
  (for/fold ([acc #f]) ([f (in-list fills)] #:when (covers? f line col))
    (list-ref f 4)))

;; 一格的层（单 face / face-stack）：多个插件写同一格时不去掉谁，而是叠层。
(define (last-palette v kind)
  (for/last ([l (in-list (face-layers v))]
             #:when (and (palette-color? l) (eq? (palette-color-kind l) kind)))
    l))
(define (bracket-index v) (palette-color-index (last-palette v 'bracket)))
(define (word-index v) (palette-color-index (last-palette v 'word)))
(define (has-face? v f) (for/or ([l (in-list (face-layers v))]) (equal? l f)))

(define bf (bracket-fills "(a[b]c)\n((x))\n"))
(check-equal? (palette-color-index (face-at bf 0 0)) 0)        ; (
(check-equal? (palette-color-index (face-at bf 0 1)) 0)        ; a 在 (…) 内
(check-equal? (palette-color-index (face-at bf 0 2)) 1)        ; [
(check-equal? (palette-color-index (face-at bf 0 3)) 1)        ; b 在 […] 内
(check-equal? (palette-color-index (face-at bf 0 5)) 0)        ; c 在 (…) 内
(check-equal? (palette-color-index (face-at bf 1 2)) 1)        ; x 在内层
(check-equal? (palette-color-index (face-at bf 1 4)) 0)        ; ) 外层
(check-false (face-at (bracket-fills "(a[b])z") 0 6))      ; 括号外不上色
(check-false (face-at (bracket-fills "(]") 0 0))           ; 未配对不产生区间
(check-equal? (length (bracket-fills "no brackets")) 0)

;;; ---------- 主题：动态 face 取模取背景色 ----------

(check-equal? (call-with-values (lambda () (theme-face-colors (current-theme) (palette-color 'bracket 0))) list)
              '(#f (70 56 90)))
(check-equal? (call-with-values (lambda () (theme-face-colors (current-theme) (palette-color 'bracket 4))) list)
              '(#f (70 56 90)))                      ; 深度 4 回到色板第 0 个
(check-equal? (call-with-values (lambda () (theme-face-colors light-theme (palette-color 'bracket 1))) list)
              '(#f (214 238 230)))

;;; ---------- 影子文本：增量 splice ----------

(check-equal? (shadow-text (shadow-open "a\nb\n")) "a\nb\n")     ; 保留行尾空行
(check-equal? (shadow-text (shadow-open "")) "")
(check-equal? (shadow-text (shadow-apply (shadow-open "ab\ncd\nef") (list (list 0 1 1 1 "X"))))
              "aXd\nef")                                            ; 跨行 replace
(check-equal? (shadow-text (shadow-apply (shadow-open "abc") (list (list 0 1 0 2 ""))))
              "ac")                                                 ; 行内删除
(check-equal? (shadow-text (shadow-apply (shadow-open "ab") (list (list 0 1 0 1 "\n"))))
              "a\nb")                                               ; 插入换行
(check-equal? (shadow-text (shadow-apply (shadow-open "a\nb") (list (list 0 1 1 0 ""))))
              "ab")                                                 ; 删换行合并行

;;; ---------- manager + 同步 runner ----------

(define ed (make-blank-editor))
(define-values (ed1 did vid) (editor-add-document-view ed "(a[b])" 40 10 "t.txt"))
;; 只跑括号插件：本段验证的是版本闸门 / 增量，不受词 / 关键字插件干扰。
(define m (make-manager (list bracket-plugin) (make-sync-runner)))

(manager-sync! m ed1 (list (list did "/t.txt")))
(check-not-false (member did (manager-poll! m ed1)))
(check-equal? (bracket-index (editor-document-highlight-at ed1 did 0 0)) 0)
(check-equal? (bracket-index (editor-document-highlight-at ed1 did 0 2)) 1)
(check-equal? (bracket-index (editor-document-highlight-at ed1 did 0 1)) 0)
(check-false (editor-document-highlight-at ed1 did 0 6))    ; 越界 → 无

;; 同版本不重复派活
(check-equal? (manager-poll! m ed1) '())
(check-equal? (manager-poll! m ed1) '())

;; 版本闸门：派活后、poll 前文本又变 → 旧结果被丢，不写回
(editor-view-insert! ed1 vid "x")                           ; → "x(a[b])"（新 doc 值）
(manager-sync! m ed1 (list (list did "/t.txt")))            ; 为 D1 派活（同步算完入队）
(editor-view-insert! ed1 vid "y")                           ; → "xy(a[b])"（D2）
(check-equal? (manager-poll! m ed1) '())                    ; D1 结果过期 → 丢
(manager-sync! m ed1 (list (list did "/t.txt")))            ; 为 D2 派活
(check-not-false (member did (manager-poll! m ed1)))
(check-equal? (bracket-index (editor-document-highlight-at ed1 did 0 2)) 0)  ; (
(check-equal? (bracket-index (editor-document-highlight-at ed1 did 0 4)) 1)  ; [
(check-false (editor-document-highlight-at ed1 did 0 0))                     ; x 在括号外

;; forget：不再写回（文档列表里已无该 did）
(manager-forget! m did)
(check-equal? (manager-poll! m ed1) '())

;; 增量路径：编辑命令记下 change → sync 发 change!（而不是整篇 open）
(define ed2 (make-blank-editor))
(define-values (ed2* did2 vid2) (editor-add-document-view ed2 "(a)" 40 10 "i.txt"))
(define m3 (make-manager (list bracket-plugin) (make-sync-runner)))
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-not-false (member did2 (manager-poll! m3 ed2*)))
(check-equal? (bracket-index (editor-document-highlight-at ed2* did2 0 1)) 0)
(define-values (chs2 _ok2) (editor-view-insert! ed2* vid2 "b"))    ; → "b(a)"
(manager-note-change! m3 did2
  (for/list ([ch (in-list chs2)])
    (define b (change-before ch))
    (list (point-line (range-start b)) (point-column (range-start b))
          (point-line (range-end b)) (point-column (range-end b))
          (editor-view-change-text ed2* vid2 ch))))
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-not-false (member did2 (manager-poll! m3 ed2*)))
(check-false (editor-document-highlight-at ed2* did2 0 0))          ; b 在括号外
(check-equal? (bracket-index (editor-document-highlight-at ed2* did2 0 1)) 0)  ; (
(check-equal? (bracket-index (editor-document-highlight-at ed2* did2 0 2)) 0)  ; a

;; undo：属性已在恢复出的 document 里 → 影子在、结果在 → 不重发、不重算
(editor-view-undo! ed2* vid2)                                       ; "b(a)" → "(a)"
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-equal? (manager-poll! m3 ed2*) '())                          ; 没派活
(check-equal? (bracket-index (editor-document-highlight-at ed2* did2 0 1)) 0)  ; 恢复的旧属性
;; redo 也一样
(editor-view-redo! ed2* vid2)
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-equal? (manager-poll! m3 ed2*) '())
(check-equal? (bracket-index (editor-document-highlight-at ed2* did2 0 1)) 0)

;;; ---------- 两个语法插件：词着色 + Racket 关键字（覆盖顺序 = registry 顺序）----------

(define ed4 (make-blank-editor))
(define-values (ed4* did4 vid4)
  (editor-add-document-view ed4 "(define (a b) a)" 40 10 "k.rkt"))
(define m4 (make-manager registry-plugins (make-sync-runner)))
(manager-sync! m4 ed4* (list (list did4 "/k.rkt")))
(check-not-false (member did4 (manager-poll! m4 ed4*)))
(define (face4 line col) (editor-document-highlight-at ed4* did4 line col))
;; 列：0( 1-6define 7空格 8( 9a 10空格 11b 12) 13空格 14a 15)
;; define 是关键字：同一格既有括号背景，又有语法前景（叠层，不再互相覆盖）
(check-true (has-face? (face4 0 1) 'syn-keyword))       ; 关键字前景层
(check-equal? (bracket-index (face4 0 1)) 0)            ; 背景层仍在（括号深度）
(check-not-false (last-palette (face4 0 9) 'word))      ; a → 词色前景
(check-not-false (last-palette (face4 0 11) 'word))     ; b → 词色前景
(check-equal? (last-palette (face4 0 9) 'word)          ; 同一个词 a → 同一个颜色
              (last-palette (face4 0 14) 'word))
(check-equal? (bracket-index (face4 0 0)) 0)            ; ( 仍是括号背景
(check-equal? (bracket-index (face4 0 8)) 1)            ; 内层 ( 的背景深度 1

;; 主题逐分量合并：前景取语法层，背景取括号层
(check-equal? (call-with-values
               (lambda () (theme-face-colors (current-theme)
                            (face-stack (list (palette-color 'bracket 0) 'syn-keyword))))
               list)
              '((230 160 90) (70 56 90)))

;; 非 .rkt 文件：关键字插件不生效，define 仍是词色
(define ed5 (make-blank-editor))
(define-values (ed5* did5 vid5)
  (editor-add-document-view ed5 "(define (a b) a)" 40 10 "k.txt"))
(define m5 (make-manager registry-plugins (make-sync-runner)))
(manager-sync! m5 ed5* (list (list did5 "/k.txt")))
(check-not-false (member did5 (manager-poll! m5 ed5*)))
(check-not-false (last-palette (editor-document-highlight-at ed5* did5 0 1) 'word))

;;; ---------- 后台 place runner（真·独立进程） ----------

(define m2 (make-manager (list bracket-plugin) (make-place-runner 1)))
(manager-sync! m2 ed1 (list (list did "/t.txt")))
(define (wait-applied! n)
  (cond
    [(zero? n) #f]
    [else
     (manager-poll! m2 ed1)
     (if (last-palette (editor-document-highlight-at ed1 did 0 2) 'bracket)
         #t
         (begin (sleep 0.05) (wait-applied! (sub1 n))))]))
(check-true (wait-applied! 200))                            ; ≤10s
(check-equal? (bracket-index (editor-document-highlight-at ed1 did 0 4)) 1)
(manager-stop! m2)

(displayln "lab smoke-plugin: ok")
