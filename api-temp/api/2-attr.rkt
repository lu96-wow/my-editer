#lang racket

;;; api-temp/api/2-attr.rkt —— 底层原理 · 属性
;;;
;;; 只讲 core/api.rkt 门面里的属性能力：attr-desc / attrs（unit 层）/ document 属性写 / read-only 守卫。
;;; editor 层的属性命令（editor-document-*-attr*）在 api-temp/editor/2-attr.rkt。
;;;
;;; 属性 = 与文本同坐标的一块平行 buffer：行内区间 [start,end) 上挂一个 hash（key/值由使用方定义）。
;;; 两条写路径：
;;;   · 文本编辑时**跟随**（attrs-apply-edit）：吃生效 edit-desc，新文本不继承属性；
;;;   · 显式属性变更（attrs-apply-attr[-batch]）：吃 attr-desc。
;;; core 只保留并解释一个 key：'read-only（用于守卫），其余 key 全不透明。
;;;
;;; 运行：racket api-temp/api/2-attr.rkt

(require "../../core/api.rkt")

(define (show label v) (printf "~a\n    => ~v\n" label v))
(define (header s) (printf "\n========== ~a ==========\n" s))
(define (P l c) (point l c))

;;; ===========================================================================
(header "1. attr-desc —— 属性变更原子")
;;; ===========================================================================

;; 设计：与 edit-desc 并列的变更原子——edit-desc 改文本，attr-desc 改属性。
;;   和 edit-desc 一样**不含旧值**，所以能打包进 change、进账本、可重放。
;;   约束：start/end 必须**同一行**（属性是行内区间）、半开、零宽 = no-op。
;; 用法：set（设 key→val）/ remove（去 key）；坐标是「施加前」。
(define ad (attr-desc (P 0 1) (P 0 4) 'face 'set 'bold))
(show "(attr-desc (point 0 1) (point 0 4) 'face 'set 'bold)" ad)
(show "(attr-desc-start ad)" (attr-desc-start ad))
(show "(attr-desc-end ad)" (attr-desc-end ad))
(show "(attr-desc-key ad)" (attr-desc-key ad))
(show "(attr-desc-op ad)" (attr-desc-op ad))
(show "(attr-desc-val ad)" (attr-desc-val ad))

;; attr-set / attr-remove : point point symbol [val] → attr-desc
(show "(attr-set (point 0 1) (point 0 3) 'face 'bold)" (attr-set (P 0 1) (P 0 3) 'face 'bold))
(show "(attr-remove (point 0 1) (point 0 3) 'face)" (attr-remove (P 0 1) (P 0 3) 'face))

;; attr-desc-empty? : attr-desc → boolean（零宽 = no-op）
;;   设计：零宽没有合法解释为「标注某段」，唯一语义是 no-op，显式判掉。
(show "(attr-desc-empty? (attr-set (point 0 2) (point 0 2) 'k #t))"
      (attr-desc-empty? (attr-set (P 0 2) (P 0 2) 'k #t)))

;;; ===========================================================================
(header "2. attrs —— 属性 buffer（unit 层：纯值 + 显式施加）")
;;; ===========================================================================

;; 设计：attrs 与 content（文本）**同坐标、平行**，保持不变量：
;;   P1 每行内段按起点升序互不重叠；P2 相邻同 hash 已合并；P3 空 hash 段不留；P4 行数 = 文本行数。
;;   读口一律返回「覆盖整行」的段（含空 hash），这样前端能无脑铺满一行。

;; attrs-empty : nat → attrs（总行数；行号由下标表达）
(define a0 (attrs-empty 3))
(show "(attrs? a0)" (attrs? a0))
(show "(attrs-line-count a0)" (attrs-line-count a0))

;; attrs-apply-attr : attrs symbol attr-desc → attrs
;;   设计：显式写路径；set 保留同区间其它 key，只改这一个 key。零宽 → 恒等（同一值）。
;;   who 只是报错定位用的名字。
(define a1 (attrs-apply-attr a0 'demo (attr-set (P 0 1) (P 0 4) 'face 'bold)))
(show "(attrs? a1)" (attrs? a1))
(show "(attrs-apply-attr 零宽 → 同一值? )" (eq? a1 (attrs-apply-attr a1 'demo (attr-set (P 0 2) (P 0 2) 'x #t))))

;; attrs-apply-attr-batch : attrs symbol (listof attr-desc) → attrs
;;   设计：批量一次施加（按行分组，每行只拷一次）；同 (line,key) 区间不得重叠（否则逆不成立）。
(define a2 (attrs-apply-attr-batch a0 'demo (list (attr-set (P 0 0) (P 0 3) 'face 'bold)
                                                  (attr-set (P 1 0) (P 1 2) 'face 'italic))))
(show "(attrs-key-runs a2 0 6 'face)" (attrs-key-runs a2 0 6 'face))
(show "(attrs-key-runs a2 1 6 'face)" (attrs-key-runs a2 1 6 'face))

;; attrs-at : attrs point → hash（该点的属性 hash；无覆盖 → 空 hash）
(show "(attrs-at a1 (point 0 2))" (attrs-at a1 (P 0 2)))
(show "(attrs-at a1 (point 0 4))" (attrs-at a1 (P 0 4)))    ; 半开：右端点不含

;; attrs-runs / attrs-key-runs : attrs nat nat [symbol] → (listof (list start end hash|val))
;;   设计：runs 含本行**所有** key（给「有没有属性」用）；key-runs 只取一个 key（给投影用，
;;         别的 key 的边界不会把这个 key 的段切断）。
(show "(attrs-runs a1 0 6)" (attrs-runs a1 0 6))
(define a3 (attrs-apply-attr a1 'demo (attr-set (P 0 2) (P 0 3) 'ro #t)))
(show "(attrs-runs a3 0 6)" (attrs-runs a3 0 6))
(show "(attrs-key-runs a3 0 6 'face)" (attrs-key-runs a3 0 6 'face))
(show "(attrs-key-runs a3 0 6 'ro)" (attrs-key-runs a3 0 6 'ro))

;; attrs-range-runs : attrs point point → (listof (list line start end hash))（跨行捕获）
;;   设计：文本编辑**抹掉**某区间时，先用它把该区间的属性捕获下来，撤销时补回。
(show "(attrs-range-runs a1 (point 0 2) (point 0 3))" (attrs-range-runs a1 (P 0 2) (P 0 3)))
(show "(attrs-range-runs a1 (point 0 0) (point 1 0))" (attrs-range-runs a1 (P 0 0) (P 1 0)))

;; attrs-apply-edit : attrs edit-desc → attrs
;;   设计：文本编辑时属性**跟随**——区内右半后移、跨切点的段被切开；
;;         **新插入的文本不继承属性**（否则复制格式会到处传染）。
(show "(attrs-apply-edit a1 在(0,2)插x) → key-runs"
      (attrs-key-runs (attrs-apply-edit a1 (edit-desc (P 0 2) (P 0 2) "x")) 0 7 'face))
(show "(attrs-apply-edit a1 删[0,2)) → key-runs"
      (attrs-key-runs (attrs-apply-edit a1 (edit-desc (P 0 0) (P 0 2) "")) 0 4 'face))

;; attrs-desc-inverse : attrs attr-desc → (listof attr-desc)（恢复 d 之前的 key 状态）
;;   设计：显式属性的逆（同坐标、依次施加可精确回退）。文本编辑抹掉的属性另走 erased-restores。
(show "(attrs-desc-inverse a1 (attr-set (0,0)-(0,6) face x))"
      (attrs-desc-inverse a1 (attr-set (P 0 0) (P 0 6) 'face 'x)))

;; attrs-check : attrs nat → attrs（校验 P1-P4；行数与文本不一致就报错）
;;   设计：开发期/不变量校验用；生产路径由漏斗保证，不必每步调用。
(show "(attrs-check a0 3) → a0" (eq? a0 (attrs-check a0 3)))
(show "(attrs-check 行数不符 → 抛错)"
      (with-handlers ([exn:fail? (lambda (e) (exn-message e))]) (attrs-check a0 2)))

;;; ===========================================================================
(header "3. document 层属性读写（推荐：与文本同一条漏斗，带撤销材料）")
;;; ===========================================================================

(define d0 (document-open "hello\nworld"))

;; document-put-attr : document symbol nat nat nat any/c → document
;;   设计：单段 set 的便利封装——保留同区间其它 key，只改这一个。零宽 = 恒等。
;;         走 change 漏斗，所以只涨 attr-tick，不涨 text-tick。
(define d1 (document-put-attr d0 'face 0 0 5 'bold))
(show "(document-attrs-at d1 (point 0 2))" (document-attrs-at d1 (P 0 2)))
(show "(document-attrs-runs d1 0)" (document-attrs-runs d1 0))
(show "(document-attrs-key-runs d1 0 'face)" (document-attrs-key-runs d1 0 'face))
(show "(document-attr-tick d1)  ; 属性写 +1，文本 tick 不变" (list (document-attr-tick d1) (document-text-tick d1)))
(show "(document-content-eq? d0 d1)  ; 文本没变" (document-content-eq? d0 d1))

;; document-remove-attr : document symbol nat nat nat → document
(define d2 (document-remove-attr d1 'face 0 2 4))
(show "(document-attrs-key-runs d2 0 'face)" (document-attrs-key-runs d2 0 'face))

;; document-replace-attr : document symbol spans #:lines l0 l1 → document
;;   设计：**替换语义**——「该 key 在 [l0,l1] 行的值变成且仅变成 spans」，范围内没给的行清空。
;;         给「重算一整块派生标注」用，省去自己算 diff。
(define d3 (document-replace-attr d0 'face (list (list 0 1 3 'bold) (list 1 0 2 'italic)) #:lines 0 1))
(show "(document-attrs-key-runs d3 0 'face)" (document-attrs-key-runs d3 0 'face))
(show "(document-attrs-key-runs d3 1 'face)" (document-attrs-key-runs d3 1 'face))
(define d4 (document-replace-attr d3 'face '() #:lines 1 1))     ; 只清第 1 行
(show "(replace 清第1行后 d4 line1)" (document-attrs-key-runs d4 1 'face))
(show "(replace 范围外 line0 不动)" (document-attrs-key-runs d4 0 'face))

;; 属性 + 文本一条 change
;;   设计：attrs 坐标 = texts 生效之后，所以能「插入文本并给它标只读」一次完成。
;;   change-result 的属性撤销材料有两块：attr-inverses（显式属性逆）+ erased-restores（被文本抹掉的）。
(define-values (d5 res5)
  (document-apply-change d0
    (change (list (edit-desc (P 0 1) (P 0 1) "X"))
            (list (attr-set (P 0 1) (P 0 2) read-only-key #t)))))
(show "(document->string d5)" (document->string d5))
(show "(document-attrs-key-runs d5 0 read-only-key)" (document-attrs-key-runs d5 0 read-only-key))
(show "(change-result-attr-inverses res5)" (change-result-attr-inverses res5))
(show "(change-result-erased-restores res5)" (change-result-erased-restores res5))
(show "(change-result-undo res5)" (change-result-undo res5))

;; 撤销后属性一并回退
(define d5-undo
  (for/fold ([d d5]) ([c (in-list (change-result-undo res5))])
    (let-values ([(d* _) (document-apply-change d c #:trusted? #t)]) d*)))
(show "(撤销后 文本 / read-only)" (list (document->string d5-undo)
                                        (attr-read-only? (document-attrs-at d5-undo (P 0 1)))))

;;; ===========================================================================
(header "4. read-only 守卫（core 唯一解释的保留 key）")
;;; ===========================================================================

;; 设计：core 对属性的 key 全不透明，**只**解释 'read-only：
;;   零宽插入落点在半开只读段内 → 拒；非零宽删除与只读段相交 → 拒。
;;   拒绝的表现是「命令返回 #f / report=#f」，文档一个字节都不变。
;;   #:trusted? #t 用于程序化写入（源头已判过），避免二次守卫导致镜像分叉。
(show "read-only-key" read-only-key)
(show "(attr-read-only? (hash read-only-key #t))" (attr-read-only? (hash read-only-key #t)))
(show "(attr-read-only? (hash))" (attr-read-only? (hash)))

(define ro (document-put-attr (document-open "abc") read-only-key 0 0 3 #t))
(define-values (ro1 r1) (document-edit-at ro (P 0 1) (buffer-op-insert-char #\X)))
(show "(只读区内插入) → (values 文档 desc)" (list (document->string ro1) r1))
(define-values (ro2 r2) (document-edit-at ro (P 0 1) (buffer-op-insert-char #\X) #:trusted? #t))
(show "(#:trusted? #t 强插)" (list (document->string ro2) r2))
;; 零宽插入按半开跨度判断：右端点允许（插在只读段右端不算「落在里面」）
(define-values (ro3 _a1) (document-edit-at ro (P 0 3) (buffer-op-insert-char #\X)))
(show "(右端点 (0,3) 插入允许)" (document->string ro3))
(define-values (ro4 r4) (document-edit-at ro (P 0 2) (buffer-op-splice (P 0 2) (P 0 3) "")))
(show "(删除与只读相交) desc" r4)

;;; ===========================================================================
(header "5. 属性随文本移动（一个演示串起来）")
;;; ===========================================================================

;; 在 ro 区间**前面**插入：整体右移（端点在编辑点之后统一平移）
(define t0 (document-put-attr (document-open "abcdef") read-only-key 0 2 5 #t))
(define-values (t1 _a2) (document-apply-edit t0 (edit-desc (P 0 1) (P 0 1) "XY")))
(show "插入前 read-only runs" (document-attrs-key-runs t0 0 read-only-key))
(show "插入后（整体右移）" (list (document->string t1) (document-attrs-key-runs t1 0 read-only-key)))

;; 在 ro 区间**内部**插入：段被切成两段，新文本无属性
(define t2 (document-put-attr (document-open "abcdef") read-only-key 0 1 4 #t))
(define-values (t3 _a3) (document-apply-edit t2 (edit-desc (P 0 2) (P 0 2) "XY") #:trusted? #t))
(show "区间内插入（trusted）" (list (document->string t3) (document-attrs-key-runs t3 0 read-only-key)))

(printf "\napi/2-attr.rkt 跑完（没有报错）。\n")
