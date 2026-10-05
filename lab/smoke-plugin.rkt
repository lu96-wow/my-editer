#lang racket

;;; lab/smoke-plugin.rkt —— 插件层冒烟
;;;
;;; 覆盖：括号纯扫描 / 插件协议 / 版本闸门 / 合并（同步 runner）/ 后台 place runner。

(require rackunit
         "../core/editor.rkt"
         "base/face.rkt"
         "base/brackets.rkt"
         "plugin/api.rkt"
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

(define bf (bracket-fills "(a[b]c)\n((x))\n"))
(check-equal? (bracket-depth-n (face-at bf 0 0)) 0)        ; (
(check-equal? (bracket-depth-n (face-at bf 0 1)) 0)        ; a 在 (…) 内
(check-equal? (bracket-depth-n (face-at bf 0 2)) 1)        ; [
(check-equal? (bracket-depth-n (face-at bf 0 3)) 1)        ; b 在 […] 内
(check-equal? (bracket-depth-n (face-at bf 0 5)) 0)        ; c 在 (…) 内
(check-equal? (bracket-depth-n (face-at bf 1 2)) 1)        ; x 在内层
(check-equal? (bracket-depth-n (face-at bf 1 4)) 0)        ; ) 外层
(check-false (face-at (bracket-fills "(a[b])z") 0 6))      ; 括号外不上色
(check-false (face-at (bracket-fills "(]") 0 0))           ; 未配对不产生区间
(check-equal? (length (bracket-fills "no brackets")) 0)

;;; ---------- 主题：动态 face 取模取背景色 ----------

(check-equal? (call-with-values (lambda () (theme-face-colors (current-theme) (bracket-depth 0))) list)
              '(#f (70 56 90)))
(check-equal? (call-with-values (lambda () (theme-face-colors (current-theme) (bracket-depth 4))) list)
              '(#f (70 56 90)))                      ; 深度 4 回到色板第 0 个
(check-equal? (call-with-values (lambda () (theme-face-colors light-theme (bracket-depth 1))) list)
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
(define m (make-manager registry-plugins (make-sync-runner)))

(manager-sync! m ed1 (list (list did "/t.txt")))
(check-not-false (member did (manager-poll! m ed1)))
(check-equal? (editor-document-highlight-at ed1 did 0 0) (bracket-depth 0))
(check-equal? (editor-document-highlight-at ed1 did 0 2) (bracket-depth 1))
(check-equal? (editor-document-highlight-at ed1 did 0 1) (bracket-depth 0))
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
(check-equal? (editor-document-highlight-at ed1 did 0 2) (bracket-depth 0))  ; (
(check-equal? (editor-document-highlight-at ed1 did 0 4) (bracket-depth 1))  ; [
(check-false (editor-document-highlight-at ed1 did 0 0))                     ; x 在括号外

;; forget：不再写回（文档列表里已无该 did）
(manager-forget! m did)
(check-equal? (manager-poll! m ed1) '())

;; 增量路径：编辑命令记下 change → sync 发 change!（而不是整篇 open）
(define ed2 (make-blank-editor))
(define-values (ed2* did2 vid2) (editor-add-document-view ed2 "(a)" 40 10 "i.txt"))
(define m3 (make-manager registry-plugins (make-sync-runner)))
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-not-false (member did2 (manager-poll! m3 ed2*)))
(check-equal? (editor-document-highlight-at ed2* did2 0 1) (bracket-depth 0))
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
(check-equal? (editor-document-highlight-at ed2* did2 0 1) (bracket-depth 0))  ; (
(check-equal? (editor-document-highlight-at ed2* did2 0 2) (bracket-depth 0))  ; a

;; undo：属性已在恢复出的 document 里 → 影子在、结果在 → 不重发、不重算
(editor-view-undo! ed2* vid2)                                       ; "b(a)" → "(a)"
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-equal? (manager-poll! m3 ed2*) '())                          ; 没派活
(check-equal? (editor-document-highlight-at ed2* did2 0 1) (bracket-depth 0))  ; 恢复的旧属性
;; redo 也一样
(editor-view-redo! ed2* vid2)
(manager-sync! m3 ed2* (list (list did2 "/i.txt")))
(check-equal? (manager-poll! m3 ed2*) '())
(check-equal? (editor-document-highlight-at ed2* did2 0 1) (bracket-depth 0))

;;; ---------- 后台 place runner（真·独立进程） ----------

(define m2 (make-manager registry-plugins (make-place-runner 1)))
(manager-sync! m2 ed1 (list (list did "/t.txt")))
(define (wait-applied! n)
  (cond
    [(zero? n) #f]
    [else
     (manager-poll! m2 ed1)
     (if (bracket-depth? (editor-document-highlight-at ed1 did 0 2))
         #t
         (begin (sleep 0.05) (wait-applied! (sub1 n))))]))
(check-true (wait-applied! 200))                            ; ≤10s
(check-equal? (editor-document-highlight-at ed1 did 0 4) (bracket-depth 1))
(manager-stop! m2)

(displayln "lab smoke-plugin: ok")
