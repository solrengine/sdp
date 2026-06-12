# The four columns Solrengine::Sdp::WalletOwner expects on the wallet-owner
# model. Using a model other than User? Rename the table below and set
# `config.user_class` in config/initializers/solrengine_sdp.rb.
class AddSolrengineSdpToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :sdp_wallet_id, :string            # SDP's walletId once provisioned
    add_column :users, :wallet_address, :string           # the wallet's Solana public key
    add_column :users, :sdp_provisioning_state, :string, default: "pending", null: false
    add_column :users, :sdp_provisioning_error, :string   # renderable failure reason

    add_index :users, :sdp_provisioning_state
  end
end
