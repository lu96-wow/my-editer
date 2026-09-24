#lang racket

;;; api-temp/editor/2-attr.rkt —— 最终 API · 属性（core/editor.rkt）
;;;
;;; 底层属性（attr-desc / attrs / document-put-attr / read-only 守卫）在 api-temp/api/2-attr.rkt。
;;; 这里只讲 **editor 层** 的属性命令。
;;;
;;; 与 api 层的三点区别（也是为什么要有 editor 层）：
;;;   ① 按 did 定位，返回 (values editor report) —— 能进账本、能撤销；
;;;   ② 可以和文本编辑**打包成一条命令**（#:attrs 计划）—— 一次换 buffer、一步撤销；
;;;   ③ 属性写默认「跟随文档历史策略」，派生 UI 用 #:history? #f 就不会污染用户历史。
;;;
;;; 运行：racket api-temp/editor/2-attr.rkt

(require "../../core/editor.rkt"
         "../../core/api.rkt")     ; point / attr-set / attr-remove / read-only-key …

(define (show label v) (printf "~a\n    => ~v\n" label v))
(define (header s) (printf "\n========== ~a ==========\n" s))
(define (P l c) (point l c))

;;; ===========================================================================
(header "1. editor 层属性写（返回 (values editor report)，默认入账）")
;;; ===========================================================================

(define e0 (editor-open "hello\nworld"))

;; editor-document-apply-attrs : editor did (listof attr-desc) #:record? → (values editor report)
;;   设计：属性写与文本编辑走**同一条变更漏斗**（只是 change 里 texts 为空），
;;         所以自动获得「一次换 document、一步账本、可撤销、可 replay」。
;;   用法：批量标属性（一次多条、跨行都行）；要一步撤销就整批走这一条。
(define-values (e1 r-e1) (editor-document-apply-attrs e0 0 (list (attr-set (P 0 0) (P 0 5) 'face 'bold))))
(show "(editor-document-attrs-key-runs e1 0 0 'face)" (editor-document-attrs-key-runs e1 0 0 'face))
(show "(change-report-attrs r-e1)" (change-report-attrs r-e1))
;; 属性版本戳只涨 attr-tick，不动 text-tick —— 前端可据此只重投影、不重扫文本。
(show "(editor-document-attr-tick e1 0)" (editor-document-attr-tick e1 0))
(show "(editor-document-can-undo? e1 0)  ; 属性写默认跟随策略入账" (editor-document-can-undo? e1 0))

;; editor-document-put-attr : editor did symbol nat nat nat any/c #:record? → (values editor report)
;;   设计：单段 set 的便利封装（保留同区间其它 key）。
;;   用法：只标一小段；整行替换用下面的 replace-attr。
(define-values (e2 _a1) (editor-document-put-attr e1 0 'face 1 0 5 'italic))
(show "(put-attr line1)" (editor-document-attrs-key-runs e2 0 1 'face))

;; editor-document-remove-attr : editor did symbol nat nat nat #:record? → (values editor report)
;;   设计：单段 remove（只去掉这个 key，不动其它 key）。
(define-values (e3 _a2) (editor-document-remove-attr e2 0 'face 0 2 4))
(show "(remove-attr [2,4))" (editor-document-attrs-key-runs e3 0 0 'face))

;; editor-document-replace-attr : editor did symbol spans #:lines l0 l1 #:record? → (values editor report)
;;   设计：**替换语义**——「该 key 在 [l0,l1] 行的值变成且仅变成 spans」，
;;         范围内没给 span 的行清空该 key。适合「重算整段高亮」这种派生标注重写。
;;   用法：syntax 高亮重扫一块区域后，把新 runs 整体覆盖；避免自己算 diff。
(define-values (e4 _a3) (editor-document-replace-attr e3 0 'face (list (list 0 3 5 'bold)) #:lines 0 0))
(show "(replace-attr line0 → [3,5) bold)" (editor-document-attrs-key-runs e4 0 0 'face))

;; 读口（同 document 层，但按 did）
(show "(editor-document-attrs-at e4 0 (point 0 3))" (editor-document-attrs-at e4 0 (P 0 3)))
(show "(editor-document-attrs-runs e4 0 0)" (editor-document-attrs-runs e4 0 0))
(show "(editor-document-attrs-key-runs e4 0 0 'face)" (editor-document-attrs-key-runs e4 0 0 'face))

;; editor-undo : 属性写也进账本，撤销把属性精确回退
(define-values (e5 _a4) (editor-undo (editor-focus-document e4 0)))
(show "(editor-undo 后 line0 face)" (editor-document-attrs-key-runs e5 0 0 'face))

;;; ===========================================================================
(header "2. 文本 + 属性一条命令（editor-command 的 #:attrs 计划）")
;;; ===========================================================================

;; #:attrs : (editor did (listof 生效 edit-desc) → (listof attr-desc))
;;   设计：属性坐标 =「文本生效之后」。这个计划在文本 descs 夹紧后求值，
;;         于是「插入一段文本并给它标只读」是一条 change：一次换 buffer、一步撤销。
;;         如果拆成两条命令，就会出现「文本变了但属性还指旧坐标」的中间态。
;;   用法：任何「新插入的文本要带属性」的场景都用它，而不是先插入再 separate 标属性。
(define ea0 (editor-open "abc"))
(define-values (ea1 ra1)
  (editor-command ea0 (edit-insert "X")
                  #:selection (list (caret (P 0 1)))
                  #:attrs (lambda (_ed _did texts)
                            (for/list ([d (in-list texts)])
                              (attr-set (edit-desc-start d) (edit-desc-after-position d)
                                        read-only-key #t)))
                  #:reaction 'leader #:record? #t))
(show "(文本)" (editor-document->string ea1 0))
(show "(属性：插入的 X 标只读)" (editor-document-attrs-key-runs ea1 0 0 read-only-key))
(show "(change-report texts / attrs)" (list (change-report-texts ra1) (change-report-attrs ra1)))
(show "(undo-depth：文本+属性一步)" (editor-document-undo-depth ea1 0))
(define-values (ea2 _a5) (editor-undo ea1))
(show "(撤销后 文本 / read-only)" (list (editor-document->string ea2 0)
                                        (editor-document-attrs-key-runs ea2 0 0 read-only-key)))

;;; ===========================================================================
(header "3. editor 命令层的 read-only 守卫")
;;; ===========================================================================

;; 设计：core 只解释一个保留 key：'read-only。编辑落在只读区 → 命令返回 report=#f（什么都没发生）。
;;       #:trusted? #t 用于「程序化写入 / 镜像同步」——那些写入的合法性已由源头保证，不该被守卫再拦。
;; 用法：用户编辑保持默认（守）；同步/插件写目标文档时 #:trusted? #t。
(define-values (er0 _a6) (editor-document-put-attr (editor-open "abc") 0 read-only-key 0 0 3 #t #:record? #f))
(define-values (er1 rr1) (editor-command er0 (edit-insert-char #\X)
                                         #:selection (list (caret (P 0 1)))))
(show "(只读区内编辑) → (values 文本 report)" (list (editor-document->string er1 0) rr1))
(define-values (er2 _a7) (editor-command er0 (edit-insert-char #\X)
                                         #:selection (list (caret (P 0 1))) #:trusted? #t))
(show "(#:trusted? #t 强写)" (editor-document->string er2 0))

(printf "\neditor/2-attr.rkt 跑完（没有报错）。\n")
