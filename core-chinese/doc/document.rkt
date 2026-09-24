#lang racket

(require "../atom/point.rkt" "../atom/content.rkt" "../atom/edit.rkt"
         "../atom/selection.rkt" "../atom/attr.rkt" "../atom/change.rkt"
         "../unit/attrs.rkt" "buffer.rkt" racket/match racket/list rackunit)

;;; doc/document.rkt —— 可编辑根：纯文本 缓冲 ⊕ 标注 属性集
;;;
;;;   文档 = 缓冲 ⊕ 属性集
;;;
;;; 缓冲 只有文本与版本号（doc/buffer.rkt）；属性集 是行内标注（unit/attrs.rkt）。
;;; 二者以 **文档** 装配，唯一变更漏斗也在这里：
;;;
;;;   文档-施加-变更[#:受信?] 施加 变更（文本 + 属性），默认带 只读 守卫
;;;   文档-施加-编辑  [#:受信?] 文本单条便利封装
;;;   文档-编辑-在     [#:受信?] 给位置与 操作 算 描述 再施加（文本）
;;;   文档-安装-属性 / -移除-属性   单段属性 set / remove（**增量**；行 + 列区间）
;;;   文档-替换-属性              某 键 在一段行范围内整体替换（**替换**语义）
;;;
;;; 编辑传播顺序（唯一）：
;;;   内容-施加（夹紧 + 生效文本 描述）
;;;   → 守卫（读 属性集）
;;;   → 属性集-施加-编辑（属性跟随；同时捕获被抹掉的属性，供撤销补回）
;;;   → 属性集-施加-属性-批（显式属性变更，坐标 = 文本生效之后）
;;;   → 缓冲 版本戳 +1
;;;
;;; core 只解释保留 键 '只读；其余 键 对 core 不透明。派生 外观 不入库
;;; （走投影参数 外观-提供者）。

(provide
 文档?                          ; 构造器/内部字段不外露
 文档-打开
 文档-缓冲
 文档-属性集
 ;; 文本委托（便利）
 文档->字符串
 文档->行列表
 文档-行-数量
 文档-行-引用
 文档-行-长度
 文档-夹紧-位置
 文档-位置->偏移
 文档-偏移->位置
 文档-范围-文本
 文档-夹紧-编辑-描述集
 文档-文本-版本戳
 文档-属性-版本戳
 文档-内容-相等?
 文档-属性集-相等?
 ;; 属性读写（通用 键→值）
 只读键
 属性-只读?
 文档-属性集-在
 文档-属性集-片段集
 文档-属性集-键-片段集
 文档-安装-属性
 文档-移除-属性
 文档-替换-属性
 文档-替换-属性-变更
 ;; 唯一变更漏斗
 文档-施加-变更
 文档-施加-编辑
 文档-编辑-在
 ;; 一次变更的完整结果
 变更-结果
 变更-结果?
 变更-结果-已施加-文本集
 变更-结果-已施加-属性集
 变更-结果-文本-逆集
 变更-结果-属性-逆集
 变更-结果-已抹除-恢复集
 变更-结果-重放
 变更-结果-撤销)

;;; ---------- 数据 ----------

(struct 文档
  (缓冲    ; doc/buffer.rkt（内容 + 文本版本 版本戳）
   属性集     ; unit/attrs.rkt
   属性-版本戳); nat   标注版本（只有属性变更 +1）
  #:transparent)

;; 一次 变更 的完整结果：生效 描述集 + 撤销材料。
(struct 变更-结果
  (已施加-文本集    ; (listof 编辑-描述)   施加顺序（起点倒序）
   已施加-属性集    ; (listof 属性-描述)   施加顺序
   文本-逆集    ; 与 已施加-文本集 平行
   属性-逆集    ; (listof (listof 属性-描述))；与 已施加-属性集 平行
   已抹除-恢复集) ; (listof 属性-描述)   原坐标：补回被文本编辑抹掉的属性
  #:transparent)

;;; ---------- 构造 / 文本委托 ----------

(define (文档-打开 s)
  (define b (缓冲-打开 s))
  (文档 b (属性集-空 (缓冲-行-数量 b)) 0))

(define (文档->字符串 d) (缓冲->字符串 (文档-缓冲 d)))
(define (文档->行列表 d)  (缓冲->行列表  (文档-缓冲 d)))
(define (文档-行-数量 d) (缓冲-行-数量 (文档-缓冲 d)))
(define (文档-行-引用 d i) (缓冲-行-引用 (文档-缓冲 d) i))
(define (文档-行-长度 d i) (缓冲-行-长度 (文档-缓冲 d) i))
(define (文档-夹紧-位置 d p) (缓冲-夹紧-位置 (文档-缓冲 d) p))
(define (文档-位置->偏移 d p) (缓冲-位置->偏移 (文档-缓冲 d) p))
(define (文档-偏移->位置 d 偏移) (缓冲-偏移->位置 (文档-缓冲 d) 偏移))
(define (文档-范围-文本 d s e) (缓冲-范围-文本 (文档-缓冲 d) s e))
(define (文档-夹紧-编辑-描述集 d 描述集) (缓冲-夹紧-编辑-描述集 (文档-缓冲 d) 描述集))
;; 文本版本（只有文本变才涨）与标注版本（只有属性变才涨）分开。
(define (文档-文本-版本戳 d) (缓冲-版本戳 (文档-缓冲 d)))
(define (文档-内容-相等? a b)
  (缓冲-内容-相等? (文档-缓冲 a) (文档-缓冲 b)))
(define (文档-属性集-相等? a b) (eq? (文档-属性集 a) (文档-属性集 b)))

;;; ---------- 属性读写 ----------

(define 只读键 '只读)
(define (属性-只读? h) (eq? #t (hash-ref h 只读键 #f)))

(define (文档-属性集-在 d p)
  (define q (缓冲-夹紧-位置 (文档-缓冲 d) p))
  (属性集-在 (文档-属性集 d) q))

(define (文档-属性集-片段集 d 行)
  (属性集-片段集 (文档-属性集 d) 行 (缓冲-行-长度 (文档-缓冲 d) 行)))

(define (文档-属性集-键-片段集 d 行 键)
  (属性集-键-片段集 (文档-属性集 d) 行 (缓冲-行-长度 (文档-缓冲 d) 行) 键))

(define (文档-安装-属性 d 键 行 c0 c1 值)
  (define-values (d* _)
    (文档-施加-变更 d (属性集->变更 (list (属性-设置 (位置 行 c0) (位置 行 c1) 键 值)))))
  d*)
(define (文档-移除-属性 d 键 行 c0 c1)
  (define-values (d* _)
    (文档-施加-变更 d (属性集->变更 (list (属性-移除 (位置 行 c0) (位置 行 c1) 键)))))
  d*)

;; 替换式：把 键 在 [l0,l1] 行的值整体换掉 —— 范围内没给 跨度集 的行清空该 键。
;; 跨度集 : (listof (list 行 c0 c1 值))；同一 (行,键) 内区间不得重叠。
;; 单行是特例：`#:行列表 L L`。
(define (文档-替换-属性-变更 d 键 跨度集 #:行列表 [l0 0] [l1 (sub1 (文档-行-数量 d))])
  (define n (文档-行-数量 d))
  (unless (<= 0 l0 l1 (sub1 n))
    (error '文档-替换-属性-变更 "行范围非法: ~a..~a（共 ~a 行）" l0 l1 n))
  (define 按-行 (make-hash))
  (for ([r (in-list 跨度集)])
    (match-define (list 行 c0 c1 值) r)
    (unless (<= l0 行 l1)
      (error '文档-替换-属性-变更 "span 行号 ~a 不在范围 ~a..~a" 行 l0 l1))
    (hash-update! 按-行 行 (lambda (l) (cons (list c0 c1 值) l)) '()))
  (属性集->变更
   (append*
    (for/list ([行 (in-range l0 (add1 l1))])
      (属性集-替换-描述集 '文档-替换-属性-变更 行 键
                           (文档-属性集-键-片段集 d 行 键)
                           (reverse (hash-ref 按-行 行 '())))))))

(define (文档-替换-属性 d 键 跨度集 #:行列表 [l0 0] [l1 (sub1 (文档-行-数量 d))])
  (define-values (d* _) (文档-施加-变更 d (文档-替换-属性-变更 d 键 跨度集 #:行列表 l0 l1)))
  d*)

;;; ---------- 只读 守卫 ----------
;;   · 零宽插入：插入点落在只读区间的半开跨度 [起点,末尾) 内 → 拒绝（右端点允许）
;;   · 非零宽删除：删除区间 [s,e) 与任一 只读 段有交集 → 拒绝

(define (行-范围-只读? b 属性集 行 a z)
  (for/or ([段 (in-list (属性集-片段集 属性集 行 (缓冲-行-长度 b 行)))])
    (match-define (list s e h) 段)
    (and (属性-只读? h) (< (max a s) (min z e)))))

(define (范围-只读? b 属性集 起点 末尾)
  (define sl (位置-行 起点)) (define sc (位置-列 起点))
  (define el (位置-行 末尾)) (define ec (位置-列 末尾))
  (cond
    [(= sl el) (行-范围-只读? b 属性集 sl sc ec)]
    [else
     (or (行-范围-只读? b 属性集 sl sc (缓冲-行-长度 b sl))
         (for/or ([l (in-range (add1 sl) el)])
           (行-范围-只读? b 属性集 l 0 (缓冲-行-长度 b l)))
         (行-范围-只读? b 属性集 el 0 ec))]))

(define (描述-只读? b 属性集 d)
  (define s (编辑-描述-起点 d))
  (define e (编辑-描述-末尾 d))
  (if (位置=? s e)
      (属性-只读? (属性集-在 属性集 (缓冲-夹紧-位置 b s)))
      (范围-只读? b 属性集 s e)))

;;; ---------- 内部：低层施加 ----------

(define (递增 b) (缓冲-递增 b))

;; 施加一条文本 描述（文本 + 属性集 跟随）；版本戳 不变。
;; 返回 (values 新 缓冲 新 属性集 生效 描述/#f)。
(define (施加-文本-描述 b 属性集 d 守卫?)
  (define-values (内容* d*) (内容-施加 (缓冲-内容 b) d))
  (cond
    [(and 守卫? (描述-只读? b 属性集 d*)) (values b 属性集 #f)]
    [else
     (values (缓冲-设置-内容 b 内容*) (属性集-施加-编辑 属性集 d*) d*)]))

;; 变更 的属性坐标 = 文本生效之后；逐条夹到生效 缓冲 的行/列域。
(define (夹紧-属性-描述 b d)
  (define s (属性-描述-起点 d)) (define e (属性-描述-末尾 d))
  (unless (= (位置-行 s) (位置-行 e))
    (error '文档-施加-变更 "属性区间必须同一行: ~a..~a" s e))
  (define l (位置-行 s))
  (when (>= l (缓冲-行-数量 b))
    (error '文档-施加-变更 "属性行号越界: ~a（buffer 行数 ~a）"
           l (缓冲-行-数量 b)))
  (define 长度 (缓冲-行-长度 b l))
  (define s* (位置 l (min (max 0 (位置-列 s)) 长度)))
  (define e* (位置 l (min (max 0 (位置-列 e)) 长度)))
  (when (位置<? e* s*)
    (error '文档-施加-变更 "属性区间反向: ~a..~a" s* e*))
  (属性-描述 s* e* (属性-描述-键 d) (属性-描述-操作 d) (属性-描述-值 d)))

;; 把 属性集-范围-片段集 的 (行 a b hash) 展开成每条 键 一条 属性-设置。
(define (片段集->属性-描述集 片段集)
  (append*
   (for/list ([r (in-list 片段集)])
     (match-define (list 行 x y h) r)
     (for/list ([(k v) (in-hash h)])
       (属性-设置 (位置 行 x) (位置 行 y) k v)))))

;; 文本批：规范化 → 按起点倒序施加 → 属性集 跟随 → 捕获被抹属性。版本戳 不变。
(define (施加-文本-批 b 属性集 描述集 守卫?)
  (define 有序 (编辑列表-规范化 '文档-施加-变更 描述集))
  (define-values (b* a* 已施加 逆列表 已抹除-acc)
    (for/fold ([b b] [属性集 属性集] [已施加 '()] [逆列表 '()] [已抹除 '()])
              ([d (in-list (reverse 有序))])
      (define b-之前 b) (define 属性集-之前 属性集)
      (define-values (bb aa dd) (施加-文本-描述 b 属性集 d 守卫?))
      (cond
        [(not dd) (values bb aa 已施加 逆列表 已抹除)]
        [else
         (define er (片段集->属性-描述集
                     (属性集-范围-片段集 属性集-之前 (编辑-描述-起点 dd) (编辑-描述-末尾 dd))))
         ;; 累积为「处理顺序的反向」；末尾一次 append*（避免逐条 append 的 O(n²)）。
         (values bb aa (cons dd 已施加)
                 (cons (缓冲-编辑-描述-逆 b-之前 dd) 逆列表)
                 (cons er 已抹除))])))
  (values b* a* (reverse 已施加) (reverse 逆列表) (append* (reverse 已抹除-acc))))

(define (文档-施加-变更 d 字符 #:受信? [受信? #f])
  (文档-施加-变更* d 字符 (not 受信?)))
(define (文档-施加-变更* d 字符 守卫?)
  (define b0 (文档-缓冲 d))
  (define-values (b1 attrs1 已施加-文本集 文本-逆列表 已抹除)
    (施加-文本-批 b0 (文档-属性集 d) (变更-文本集 字符) 守卫?))
  (define 生效-属性集
    (filter-map (lambda (x)
                  (define x* (夹紧-属性-描述 b1 x))
                  (and (not (属性-描述-空? x*)) x*))
                (变更-属性集 字符)))
  (define 属性-逆列表 (map (lambda (x) (属性集-描述-逆 attrs1 x)) 生效-属性集))
  (define 属性集* (属性集-施加-属性-批 attrs1 '文档-施加-变更 生效-属性集))
  (define 文本? (pair? 已施加-文本集))
  (define 属性集? (pair? 生效-属性集))
  (cond
    [(and (not 文本?) (not 属性集?)) (values d #f)]
    [else
     (values (文档 (if 文本? (递增 b1) b1)
                       属性集*
                       (if 属性集? (add1 (文档-属性-版本戳 d)) (文档-属性-版本戳 d)))
             (变更-结果 已施加-文本集 生效-属性集 文本-逆列表 属性-逆列表 已抹除))]))

;;; ---------- 便利入口 ----------

;; 文本单条：返回 (values 文档 生效描述/#f)。
(define (文档-施加-编辑 d 描述 #:受信? [受信? #f])
  (文档-施加-编辑* d 描述 (not 受信?)))
(define (文档-施加-编辑* d 描述 守卫?)
  (define-values (d* res) (文档-施加-变更* d (编辑列表->变更 (list 描述)) 守卫?))
  (define ds (if res (变更-结果-已施加-文本集 res) '()))
  (values d* (and (pair? ds) (car ds))))

;; 给位置与 操作（缓冲 选区 → 描述/#f），算 描述 再施加。
(define (文档-编辑-在 d p 操作 #:受信? [受信? #f])
  (文档-编辑* d p 操作 (not 受信?)))
(define (文档-编辑* d p 操作 守卫?)
  (define 描述 (操作 (文档-缓冲 d) (选区 p p)))
  (if 描述
      (文档-施加-编辑* d 描述 守卫?)
      (values d #f)))

;;; ---------- 重放 / 撤销材料 ----------

(define (变更-结果-重放 res)
  (变更 (变更-结果-已施加-文本集 res) (变更-结果-已施加-属性集 res)))
(define (变更-结果-撤销 res)
  (append
   ;; ① 显式属性的逆：同一（post）坐标，可批
   (list (属性集->变更 (append* (reverse (变更-结果-属性-逆集 res)))))
   ;; ② 文本逆：与 已施加 平行，每条坐标基于「上一条之后」——必须逆序、逐条施加
   (for/list ([x (in-list (reverse (变更-结果-文本-逆集 res)))])
     (编辑列表->变更 (list x)))
   ;; ③ 被抹掉的属性：此时文本已复原，用原坐标补回
   (list (属性集->变更 (变更-结果-已抹除-恢复集 res)))))

;;; ---------- 测试 ----------

(module+ test
  (define P (lambda (l c) (位置 l c)))
  (define ro (hash 只读键 #t))

  ;; 构造：缓冲 + 属性集
  (define d0 (文档-打开 "hello\nworld"))
  (check-equal? (文档->字符串 d0) "hello\nworld")
  (check-equal? (文档-行-数量 d0) 2)
  (check-equal? (属性集-行-数量 (文档-属性集 d0)) 2)

  ;; 文本编辑
  (define-values (d1 e1) (文档-编辑-在 d0 (P 0 0) (缓冲-操作-插入-字符 #\X)))
  (check-equal? (文档->字符串 d1) "Xhello\nworld")
  (check-equal? e1 (编辑-描述 (P 0 0) (P 0 0) "X"))
  (check-equal? (文档-文本-版本戳 d1) 1)             ; 文本版本
  (check-equal? (文档-属性-版本戳 d1) 0)

  ;; 属性读写：任意 键 独立；只读 是保留 键
  (define ab (文档-安装-属性 d0 '外观 0 1 4 '粗体))
  (check-equal? (文档-属性集-在 ab (P 0 2)) (hash '外观 '粗体))
  (check-equal? (文档-属性集-键-片段集 ab 0 '外观) (list (list 1 4 '粗体)))
  (define ab2 (文档-安装-属性 ab 只读键 0 2 3 #t))
  (check-equal? (文档-属性集-在 ab2 (P 0 2)) (hash '外观 '粗体 只读键 #t))
  (define ab3 (文档-移除-属性 ab2 只读键 0 2 3))
  (check-false (属性-只读? (文档-属性集-在 ab3 (P 0 2))))
  (check-true (文档-内容-相等? d0 ab))       ; 写属性不动文本
  (check-equal? (文档-文本-版本戳 ab) 0)             ; 文本版本不变
  (check-equal? (文档-属性-版本戳 ab) 1)        ; 标注版本 +1

  ;; 替换语义：替换-属性 把该 键 在该行范围内的值整体换掉（旧值全清）
  (define ar (文档-替换-属性 ab '外观 (list (list 0 2 3 '斜体)) #:行列表 0 0))
  (check-equal? (文档-属性集-键-片段集 ar 0 '外观) (list (list 2 3 '斜体)))
  (check-equal? (文档-属性集-键-片段集 (文档-替换-属性 ab '外观 '() #:行列表 0 0) 0 '外观) '())
  ;; 范围内没给 跨度集 的行被清空
  (define am (文档-替换-属性 ab '外观 (list (list 0 0 1 'x)) #:行列表 0 1))
  (check-equal? (文档-属性集-键-片段集 am 0 '外观) (list (list 0 1 'x)))
  (check-equal? (文档-属性集-键-片段集 am 1 '外观) '())
  (check-exn exn:fail? (lambda () (文档-替换-属性 ab '外观 (list (list 5 0 1 'x)))))
  (check-exn exn:fail? (lambda () (文档-替换-属性 ab '外观 (list (list 0 0 1 'x)) #:行列表 0 9)))

  ;; 零宽 = no-操作
  (check-eq? (文档-安装-属性 d0 'k 0 1 1 #t) d0)
  (check-eq? (文档-移除-属性 ab '外观 0 2 2) ab)
  ;; 越界 → 报错
  (check-exn exn:fail? (lambda () (文档-安装-属性 d0 'k 9 0 1 #t)))

  ;; 只读 守卫
  (define rb (文档-安装-属性 d0 只读键 0 1 4 #t))
  (define-values (rb1 rrd) (文档-编辑-在 rb (P 0 2) (缓冲-操作-插入-字符 #\X)))
  (check-eq? rb1 rb)
  (check-false rrd)
  (define-values (rb2 _) (文档-编辑-在 rb (P 0 4) (缓冲-操作-插入-字符 #\X)))
  (check-equal? (文档->字符串 rb2) "hellXo\nworld")
  (check-false (属性-只读? (文档-属性集-在 rb2 (P 0 4))))
  (define-values (rb4 rrd4) (文档-编辑-在 rb (P 0 2) (缓冲-操作-插入-字符 #\X) #:受信? #t))
  (check-equal? (文档->字符串 rb4) "heXllo\nworld")
  (check-equal? rrd4 (编辑-描述 (P 0 2) (P 0 2) "X"))

  ;; 枚举 / 清属性
  (check-equal? (文档-属性集-片段集 rb 0)
                (list (list 0 1 (hash)) (list 1 4 ro) (list 4 5 (hash))))
  (define rb-nr (文档-移除-属性 rb 只读键 0 1 4))
  (check-false (属性-只读? (文档-属性集-在 rb-nr (P 0 2))))
  (check-equal? (文档-属性集-片段集 rb-nr 0) (list (list 0 5 (hash))))

  ;; 文本 + 属性一条 变更：一次施加、一步 版本戳、报告 含两者
  (define cb0 (文档-打开 "abc"))
  (define-values (cb1 res)
    (文档-施加-变更 cb0
      (变更 (list (编辑-描述 (P 0 1) (P 0 1) "X"))
              (list (属性-设置 (P 0 1) (P 0 2) 只读键 #t)))))
  (check-equal? (文档->字符串 cb1) "aXbc")
  (check-equal? (文档-属性集-键-片段集 cb1 0 只读键) (list (list 1 2 #t)))
  (check-equal? (文档-文本-版本戳 cb1) 1)            ; 文本版本
  (check-equal? (文档-属性-版本戳 cb1) 1)       ; 标注版本
  (check-equal? (变更-结果-已施加-文本集 res) (list (编辑-描述 (P 0 1) (P 0 1) "X")))
  (check-equal? (变更-结果-已施加-属性集 res)
                (list (属性-设置 (P 0 1) (P 0 2) 只读键 #t)))
  (check-equal? (变更-结果-重放 res)
                (变更 (list (编辑-描述 (P 0 1) (P 0 1) "X"))
                        (list (属性-设置 (P 0 1) (P 0 2) 只读键 #t))))

  ;; 撤销辅助
  (define (施加-撤销 d res)
    (for/fold ([x d]) ([c (in-list (变更-结果-撤销 res))])
      (let-values ([(x* _) (文档-施加-变更 x c #:受信? #t)]) x*)))

  (define cb2 (施加-撤销 cb1 res))
  (check-equal? (文档->字符串 cb2) "abc")
  (check-false (属性-只读? (文档-属性集-在 cb2 (P 0 1))))

  ;; 回归：删除带属性的文本，撤销必须把属性一起带回
  (define eb0 (文档-安装-属性 (文档-打开 "abc") 只读键 0 0 3 #t))
  (define-values (eb1 res2)
    (文档-施加-变更 eb0 (编辑列表->变更 (list (编辑-描述 (P 0 1) (P 0 2) ""))) #:受信? #t))
  (check-equal? (文档->字符串 eb1) "ac")
  (check-equal? (文档-属性集-键-片段集 eb1 0 只读键) (list (list 0 2 #t)))
  (define eb2 (施加-撤销 eb1 res2))
  (check-equal? (文档->字符串 eb2) "abc")
  (check-equal? (文档-属性集-键-片段集 eb2 0 只读键) (list (list 0 3 #t)))

  ;; 守卫拒绝 → 什么都没发生
  (define gb (文档-安装-属性 (文档-打开 "abc") 只读键 0 0 1 #t))
  (define-values (gb1 res3) (文档-施加-变更 gb (编辑列表->变更 (list (编辑-描述 (P 0 0) (P 0 0) "Z")))))
  (check-equal? (文档->字符串 gb1) "abc")
  (check-false res3)

  (displayln "document.rkt: all tests passed"))
