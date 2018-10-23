package routing

import (
	"github.com/gorilla/mux"
	"github.com/SmartMeshFoundation/SmartRaiden-Path-Finder/common/config"
	"net/http"
	"github.com/SmartMeshFoundation/SmartRaiden-Path-Finder/common"
	"github.com/SmartMeshFoundation/SmartRaiden-Path-Finder/util"
	"github.com/SmartMeshFoundation/SmartRaiden-Path-Finder/clientapi/storage"
	"github.com/SmartMeshFoundation/SmartRaiden-Path-Finder/blockchainlistener"
)

//Setup registers HTTP handlers with the given ServeMux.
func Setup(
	apiMux *mux.Router,
	cfg config.PathFinder,
	pfsdb *storage.Database,
	ce blockchainlistener.ChainEvents,
) {
	// "/versions"
	apiMux.Handle("/pathfinder/versions",
		common.MakeExternalAPI("versions", func(req *http.Request) util.JSONResponse {
			return util.JSONResponse{
				Code: http.StatusOK,
				JSON: struct {
					Versions []string `json:"versions"`
				}{[]string{
					"v1",
				}},
			}
		}),
	).Methods(http.MethodGet, http.MethodOptions)

	vmux := apiMux.PathPrefix("/pathfinder").Subrouter()

	// "/balance"
	vmux.Handle("/{peerAddress}/balance",
		common.MakeExternalAPI("update_balance_proof", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return UpdateBalanceProof(req, ce, vars["peerAddress"])
		}),
	).Methods(http.MethodPut, http.MethodOptions)

	// "/fee_rate"
	vmux.Handle("/{peerAddress}/set_fee_rate",
		common.MakeExternalAPI("set_fee_rate", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return SetFeeRate(req, pfsdb, vars["peerAddress"])
		}),
	).Methods(http.MethodPut, http.MethodOptions)

	// "/fee_rate"
	vmux.Handle("/{peerAddress}/get_fee_rate",
		common.MakeExternalAPI("get_fee_rate", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return GetFeeRate(req, pfsdb, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)

	// "/paths"
	vmux.Handle("/{peerAddress}/paths",
		common.MakeExternalAPI("get_paths", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return GetPaths(req, ce, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)

	// "/calc_signature_balance_proof"
	vmux.Handle("/{peerAddress}/calc_signature_balance_proof",
		common.MakeExternalAPI("calc_signature_for_test", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return signDataForBalanceProof(req, cfg, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)

	// "/calc_signature_message"
	vmux.Handle("/{peerAddress}/calc_signature_message",
		common.MakeExternalAPI("calc_signature_message_for_test", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return signDataForBalanceProofMessage(req, cfg, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)

	// "/calc_signature_set_fee"
	vmux.Handle("/{peerAddress}/calc_signature_set_fee",
		common.MakeExternalAPI("calc_signature_setfee_for_test", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return signDataForSetFee(req, cfg, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)

	// "/calc_signature_get_fee"
	vmux.Handle("/{peerAddress}/calc_signature_get_fee",
		common.MakeExternalAPI("calc_signature_getfee_for_test", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return signDataForGetFee(req, cfg, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)

	// "/calc_signature_paths"
	vmux.Handle("/{peerAddress}/calc_signature_paths",
		common.MakeExternalAPI("calc_signature_paths_for_test", func(req *http.Request) util.JSONResponse {
			vars := mux.Vars(req)
			return signDataForPath(req, cfg, vars["peerAddress"])
		}),
	).Methods(http.MethodPost, http.MethodOptions)
}