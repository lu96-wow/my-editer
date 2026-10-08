#lang racket

;; 与 core/editor/history.rkt 对应的外部测试：**哑栈** —— 每次 record 都是一步，不合并。
(require rackunit
         "../../core-rebuild/editor/history.rkt"
         "../../core-rebuild/text/document.rkt"
         "../../core-rebuild/text/base/selection.rkt"
         "../../core-rebuild/text/base/point.rkt"
         "../../core-rebuild/text/base/track.rkt"
         "../../core-rebuild/text/base/edit.rkt")

(define (state-of h) (call-with-values (lambda () (history-state h)) (lambda (d s _who) (list d s))))
(define (state/who-of h) (call-with-values (lambda () (history-state h)) list))

(define (ins doc i text) (document-edit-tracks doc (edit-insert-text 0 i text)))
(define (caret-at i) (selections-one (caret (point 0 i))))

;; 记一步：以当前态为前态。
(define (record h doc* sels* [who #f])
  (define-values (pre-doc pre-sels _who) (history-state h))
  (history-record h pre-doc pre-sels doc* sels* who))

(define d0 (document-open "abc"))
(define s0 (caret-at 0))
(define h0 (history-open d0 s0))

;; ---------- 初始 ----------
(check-false (history-can-undo? h0))
(check-false (history-can-redo? h0))
(check-equal? (history-depth h0) 0)
(check-equal? (state-of h0) (list d0 s0))

;; ---------- 每次 record = 一步（哑栈不合并） ----------
(define d1 (ins d0 0 "X"))                        ; "Xabc"
(define s1 (caret-at 1))
(define h1 (record h0 d1 s1))
(check-true (history-can-undo? h1))
(check-equal? (history-depth h1) 1)
(check-equal? (state-of h1) (list d1 s1))

(define d2 (ins d1 1 "Y"))                        ; "XYabc"
(define s2 (caret-at 2))
(define h2 (record h1 d2 s2))
(check-equal? (history-depth h2) 2)               ; 连续两次编辑 = 两步
(check-equal? (state-of h2) (list d2 s2))

;; ---------- 撤销 / 重做逐级 ----------
(define-values (h3 ok3) (history-undo h2))
(check-true ok3)
(check-equal? (state-of h3) (list d1 s1))
(check-true (history-can-redo? h3))
(define-values (h4 ok4) (history-undo h3))
(check-equal? (state-of h4) (list d0 s0))
(define-values (h5 _5) (history-redo h4))
(check-equal? (state-of h5) (list d1 s1))
(define-values (h6 _6) (history-redo h5))
(check-equal? (state-of h6) (list d2 s2))

;; ---------- 新编辑截断 redo 尾巴 ----------
(define d3 (ins d1 0 "Q"))                        ; 在撤销到 d1 后新编辑
(define s3 (caret-at 1))
(define h7 (record h3 d3 s3))
(check-false (history-can-redo? h7))
(check-equal? (state-of h7) (list d3 s3))
(check-equal? (history-depth h7) 2)

;; ---------- history-merge：把 post 折叠进当前步（保留较早 pre / who / tag） ----------
(define hm1 (history-record (history-open d0 s0) d0 s0 d1 s1 0 'typing))
(check-equal? (snapshot-merge-tag (history-current hm1)) 'typing)
(check-equal? (snapshot-who (history-current hm1)) 0)
(define hm2 (history-merge hm1 d2 s2))
(check-equal? (history-depth hm2) 1)                  ; 没新增步
(check-equal? (state-of hm2) (list d2 s2))
(check-equal? (snapshot-merge-tag (history-current hm2)) 'typing)   ; tag 保留
(check-equal? (snapshot-who (history-current hm2)) 0)
(define-values (hm3 _hm3) (history-undo hm2))
(check-equal? (state-of hm3) (list d0 s0))            ; 折叠后一次撤销回到最早前态
(check-false (snapshot-merge-tag (history-current hm3)))   ; 撤销后 current = 前态，tag = #f

;; set-current 改 document / selections / who，不动 merge-tag
(define hsc (history-set-current hm1 d1 s1 0))
(check-equal? (snapshot-merge-tag (history-current hsc)) 'typing)
(check-equal? (snapshot-who (history-current hsc)) 0)
;; who 会跟着换 —— (who, selections) 必须成对更新
(define hsc2 (history-set-current hm1 d1 s1 1))
(check-equal? (snapshot-who (history-current hsc2)) 1)
(check-equal? (snapshot-selections (history-current hsc2)) s1)

;; ---------- history-seal：封口当前段（不新增步、不改文档） ----------
(check-equal? (snapshot-merge-tag (history-current hm2)) 'typing)
(define hseal (history-seal hm2))
(check-equal? (history-depth hseal) 1)                 ; 不新增步
(check-equal? (state-of hseal) (list d2 s2))           ; 文档 / 选区不变
(check-false (snapshot-merge-tag (history-current hseal)))   ; 已封口
(check-true (history-can-undo? hseal))                 ; 封口不影响撤销

;; ---------- limit：只留最近 n 步 ----------
(define hl (history-open d0 s0 1))
(define ha (record hl d1 s1))
(define hb (record ha d2 s2))
(check-equal? (history-depth hb) 1)
(define-values (hbu okbu) (history-undo hb))
(check-true okbu)
(check-equal? (state-of hbu) (list d1 s1))        ; 已丢掉最旧的初始步
(check-false (history-can-undo? hbu))

;; ---------- clear：清 undo/redo，留当前 ----------
(define hc (history-clear h2))
(check-false (history-can-undo? hc))
(check-false (history-can-redo? hc))
(check-equal? (state-of hc) (list d2 s2))

;; ---------- 边界：空历史 undo/redo 不动 ----------
(define-values (hu oku) (history-undo h0))
(check-false oku)
(check-eq? hu h0)
(define-values (hr okr) (history-redo h0))
(check-false okr)
(check-eq? hr h0)

;; ---------- readonly 搭车：set-current 不记步，undo 退到含 readonly 的步 ----------
(define ro (document-readonly-fill d0 0 1 0 2 #t))   ; "abc" 的 [1,2) 只读
(check-equal? (track-ref (document-readonly ro) 0) (vector #f #t #f))
(define hro (history-open ro s0))
(check-equal? (history-depth hro) 0)
(define hro2 (history-set-current hro ro s0 #f))         ; 同步 current（不记步）
(check-equal? (history-depth hro2) 0)
(define dro (ins ro 0 "X"))
(define hro3 (record hro2 dro s1))
(check-equal? (history-depth hro3) 1)
(define-values (hro4 _hro4) (history-undo hro3))
(check-equal? (state-of hro4) (list ro s0))
(check-equal? (track-ref (document-readonly (car (state-of hro4))) 0) (vector #f #t #f))

;; ---------- who：多视图时撤销还原发起视图的选区 ----------
(define sA (caret-at 0))
(define w0 (history-open d0 s0))
;; step1 由 who=0；step2 由 who=1
(define w1 (history-record w0 d0 s0 d1 s1 0))
(define w2 (history-record w1 d1 sA d2 s2 1))
(define-values (w3 _w3) (history-undo w2))
(check-equal? (state/who-of w3) (list d1 sA 1))       ; 撤销 step2 → step2 的前态 + who=1
(define-values (w4 _w4) (history-undo w3))
(check-equal? (state/who-of w4) (list d0 s0 0))       ; 再撤销 step1 → step1 的前态 + who=0
(check-equal? (state/who-of (let-values ([(x _) (history-redo w4)]) x)) (list d1 sA 1))

;; ---------- 记步开关（enabled?，per-document） ----------
;; 关闭：record 不新增步、只推进 current；不可 undo/redo
(define off (history-set-enabled h0 #f))
(check-false (history-enabled? off))
(define off1 (history-record off d0 s0 d1 s1))
(check-equal? (history-depth off1) 0)
(check-equal? (state-of off1) (list d1 s1))
(check-false (history-can-undo? off1))
(define-values (off2 ok-off2) (history-undo off1))
(check-false ok-off2)
(check-equal? (state-of off2) (list d1 s1))
;; 关闭期把 current 的 merge-tag 封掉（不与旧步合并）
(define hm (history-record (history-set-enabled h0 #f) d0 s0 d1 s1 0 'tag))
(check-false (snapshot-merge-tag (history-current hm)))
;; 关闭期清 future
(define hf (let-values ([(x _) (history-undo h1)]) x))          ; future 里有 d1
(check-true (history-can-redo? hf))
(define hf2 (history-record (history-set-enabled hf #f) d0 s0 d2 s2))
(check-false (history-can-redo? (history-set-enabled hf2 #t)))  ; future 已清
;; 保留 past：关闭期编辑后重开，undo 先回关闭期状态、再越过
(define keep0 (record h0 d1 s1))
(define keep1 (history-record (history-set-enabled keep0 #f) d1 s1 d2 s2 0))
(check-equal? (history-depth keep1) 1)                          ; past 保留
(define keep2 (history-record (history-set-enabled keep1 #t) d2 s2 d3 s3 0))
(check-equal? (history-depth keep2) 2)
(define keep-u1 (let-values ([(x _) (history-undo keep2)]) x))
(check-equal? (state-of keep-u1) (list d2 s2))
(check-equal? (state-of (let-values ([(x _) (history-undo keep-u1)]) x)) (list d0 s0))

(displayln "history.rkt: all tests passed")
