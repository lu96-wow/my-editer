#lang racket

(require "../viewport/window.rkt" "../doc/document.rkt")

;;; platform/state.rkt —— 编辑器 数据 + 查找
;;;
;;; 只给同目录的 写/neutral/反应/program/命令 用；**不进标准入口**。
;;; 这里只有数据与读取。
;;;
;;; 每个 文档-条目 持有一个 **文档**（纯文本 缓冲 ⊕ 标注 属性集）；
;;; 视口 看哪个文档由它的 `窗口.文档` 决定。引用完整性（任一 视口 的
;;; 窗口.文档 必是某个 文档-条目 的 文档）由 write.rkt 维持。

(provide
 (struct-out 编辑器)
 (struct-out 文档-条目)
 (struct-out 视口)
 (struct-out 变更-报告)
 视口-文档
 视口-缓冲
 取文档标识
 文档的视口
 编辑器-文档-条目
 编辑器-视口-引用
 编辑器-已聚焦-视口
 编辑器-历史
 检查同步
 检查链接)

;;; ---------- 数据 ----------

(struct 文档-条目 (标识 名称 文档 历史 记录?) #:transparent)
;; 历史 : 历史   撤销/重放账本（空栈 = 还没记过）
;; 记录? : boolean   该 文档 的**默认历史策略**：变更是否入账本（命令可用 #:记录? 覆盖）

;; 一次命令的影响（新坐标系）；命令返回 #f 表示什么都没发生。
;; 文本集 : (listof 编辑-描述) —— **施加顺序**；每个 描述 的坐标是「施加它之前」的文档状态
;;         （可直接喂 编辑列表-映射-位置，或转成 LSP 的增量 didChange）。
;; 属性集 : (listof 属性-描述) —— 本次命令施加的属性变更（施加顺序）。
;; 受影响行区间是二者的投影，由读面现算（见 neutral.rkt）。
(struct 变更-报告 (文本集 属性集) #:transparent)

(struct 视口 (标识 窗口 同步 链接) #:transparent)
;; 窗口 : 窗口            本视图看的 文档 在其内
;; 同步   : '自由 | '跟随   同 文档 的显示语义策略槽，由 反应 读取
;; 链接   : (or/c symbol? #f) 跨 文档 的视口同步链接名；#f = 不参与

(struct 编辑器 (文档列表 视口列表 焦点 下一个-文档 下一个-视口) #:transparent)
;; 文档列表   : (listof 文档-条目)   顺序稳定
;; 视口列表     : (listof 视口)           顺序稳定
;; 焦点     : (or/c #f 视口-标识)
;; 下一个-*    : nat                     下一个可用 标识

;;; ---------- 查找 ----------

;; 视口 看哪个文档：窗口 里的 文档。
(define (视口-文档 v) (窗口-文档 (视口-窗口 v)))
;; 便利：视口 看的**文本**。
(define (视口-缓冲 v) (文档-缓冲 (视口-文档 v)))

;; 文档 值 → 它在 registry 里的名字。引用完整性：找不到即错误
;; （每个 文档 值恰属于一个 条目：文档-打开/编辑都产生新值）。
(define (取文档标识 ed d)
  (define e (for/first ([e (in-list (编辑器-文档列表 ed))]
                        #:when (eq? d (文档-条目-文档 e)))
              e))
  (unless e (error '取文档标识 "这个 document 不在 editor 里：~a" d))
  (文档-条目-标识 e))

;; 同文档的第一个 视口（按 文档标识 寻址时的默认 视口）。
(define (文档的视口 ed 文档标识)
  (define d (文档-条目-文档 (编辑器-文档-条目 ed 文档标识)))
  (for/first ([v (in-list (编辑器-视口列表 ed))] #:when (eq? d (视口-文档 v))) v))

(define (编辑器-文档-条目 ed 文档标识)
  (or (for/first ([e (in-list (编辑器-文档列表 ed))] #:when (= 文档标识 (文档-条目-标识 e))) e)
      (error '编辑器 "没有这个 document id: ~a" 文档标识)))

(define (编辑器-视口-引用 ed 视口标识)
  (or (for/first ([v (in-list (编辑器-视口列表 ed))] #:when (= 视口标识 (视口-标识 v))) v)
      (error '编辑器 "没有这个 view id: ~a" 视口标识)))

(define (检查同步 报错者 s)
  (unless (memq s '(自由 跟随))
    (error 报错者 "sync 必须是 'free 或 'follow，得到 ~a" s)))

(define (检查链接 报错者 l)
  (unless (or (not l) (symbol? l))
    (error 报错者 "link 必须是符号或 #f，得到 ~a" l)))

(define (编辑器-已聚焦-视口 ed)
  (define f (编辑器-焦点 ed))
  (unless f (error '编辑器 "当前没有焦点视图"))
  (编辑器-视口-引用 ed f))

(define (编辑器-历史 ed 文档标识) (文档-条目-历史 (编辑器-文档-条目 ed 文档标识)))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "../doc/buffer.rkt")
  (define d (文档-打开 "s"))
  (define ed (编辑器 (list (文档-条目 0 "s" d 'H #t))
                     (list (视口 0 (窗口-打开 d 24 80) '自由 #f)) 0 1 1))

  (check-equal? (文档-条目-标识 (编辑器-文档-条目 ed 0)) 0)
  (check-equal? (视口-标识 (编辑器-视口-引用 ed 0)) 0)
  (check-equal? (视口-标识 (编辑器-已聚焦-视口 ed)) 0)
  (check-eq? (视口-文档 (编辑器-视口-引用 ed 0)) d)
  (check-eq? (视口-缓冲 (编辑器-视口-引用 ed 0)) (文档-缓冲 d))
  (check-equal? (取文档标识 ed d) 0)

  (check-exn exn:fail? (lambda () (编辑器-文档-条目 ed 9)))
  (check-exn exn:fail? (lambda () (检查同步 'x 'bad)))
  (displayln "state.rkt: all tests passed"))
